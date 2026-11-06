//
//  MIDIClockLeaderArbiter.swift
//  FluxKlang
//
//  Arbitrates competing MIDI clock sources. Exactly one authority drives the
//  transport: the internal clock or one explicitly selected external source.
//  Messages from any other source never move the transport; they update that
//  source's shadow follower and are counted, and the first of each kind per
//  selection is reported as a `competingSource` diagnostic.
//
//  Lock: the leader locks after N consecutive steady pulses (the policy's
//  `reacquirePulses`). A pulse is steady when its interval is positive, within
//  the timeout, and within the jitter tolerance of the previous interval; the
//  first interval after a (re)start only seeds the reference, so locking takes
//  N + 2 pulses. An interval outside the tolerance resets the count to zero and
//  becomes the new reference. Once locked, jitter never unlocks.
//
//  Loss: a leader pulse gap strictly longer than the timeout, seen when the
//  late pulse arrives or by `poll(now:)`, reports exactly one `leaderLost`.
//  The leader stays selected, its last tempo is held and the status is
//  `degraded` with a reason until N steady pulses relock it. Nothing ever
//  switches the leader automatically; `selectLeader` is the only way.
//
//  Time is caller-supplied host stamps; there is no timer or wall clock. Each
//  source's stamps and the poll stamps must not go back. Every throwing call
//  leaves the arbiter unchanged.
//

struct MIDIClockLeaderArbiter: Sendable {
    /// The leader's lock between selections.
    private enum Lock: Equatable, Sendable {
        case acquiring, locked
        case lost(MIDIClockDegradedReason)
    }

    private struct Entry: Sendable {
        let id: MIDIInputID
        var follower: MIDIClockFollower
        var lastHost: HostStamp?
        var ignored = MIDIClockIgnoredCounts()
    }

    /// The leader's run of consecutive steady pulses.
    private struct SteadyRun: Sendable {
        var lastPulse: HostStamp?
        var interval: UInt64?
        var steadyPulses = 0

        mutating func advance(to host: HostStamp, tolerancePerMille: Int, cap: Int) {
            defer { lastPulse = host }
            guard let lastPulse else { return }
            let gap = host.ticks - lastPulse.ticks
            guard gap > 0 else {
                // Pulses sharing a host time carry no interval: the count and reference restart.
                interval = nil
                steadyPulses = 0
                return
            }
            if let interval, Self.isSteady(gap, reference: interval, tolerancePerMille: tolerancePerMille) {
                steadyPulses = min(steadyPulses + 1, cap)
            } else {
                steadyPulses = 0
            }
            interval = gap
        }

        /// |gap - reference| * 1000 <= tolerance * reference, exactly.
        static func isSteady(_ gap: UInt64, reference: UInt64, tolerancePerMille: Int) -> Bool {
            let difference = gap > reference ? gap - reference : reference - gap
            return Int128(difference) * 1_000 <= Int128(tolerancePerMille) * Int128(reference)
        }
    }

    let policy: MIDIClockArbitrationPolicy
    let timebase: HostTimebase
    /// The policy timeout rounded up to whole host ticks.
    let timeoutTicks: UInt64
    private(set) var leader = MIDIClockLeader.internal
    /// Sorted by source ID.
    private var entries: [Entry] = []
    private var lock = Lock.acquiring
    private var run = SteadyRun()
    private var estimator: MIDIClockTempoEstimator
    private var tempo: MIDIClockTempoEstimate?
    private var lastPoll: HostStamp?

    init(policy: MIDIClockArbitrationPolicy = .standard,
         timebase: HostTimebase) throws(MIDIClockArbitrationError) {
        do {
            estimator = try MIDIClockTempoEstimator(timebase: timebase)
        } catch {
            throw .clock(error)
        }
        self.policy = policy
        self.timebase = timebase
        let ticks = ExactMath.ceilDiv(Int128(policy.timeoutNanos) * Int128(timebase.denom), Int128(timebase.numer))
        timeoutTicks = UInt64(ticks)
    }

    /// The leader and its lock, including the degraded reason and held tempo.
    var status: MIDIClockLeaderStatus {
        guard case let .external(id) = leader else { return .internal }
        switch lock {
        case .acquiring: return .acquiring(id, steadyPulses: run.steadyPulses)
        case .locked: return .locked(id, tempo: tempo)
        case let .lost(reason):
            return .degraded(id, reason: reason, heldTempo: tempo, steadyPulses: run.steadyPulses)
        }
    }

    /// Every registered source, in ID order.
    var sources: [MIDIClockSourceStatus] { entries.map(snapshot) }

    func source(_ id: MIDIInputID) -> MIDIClockSourceStatus? {
        index(of: id).map { snapshot(entries[$0]) }
    }

    /// Registers a source. The table holds at most `policy.maximumSources`.
    mutating func addSource(_ id: MIDIInputID) throws(MIDIClockArbitrationError) {
        let position = entries.firstIndex { $0.id >= id } ?? entries.endIndex
        guard position == entries.endIndex || entries[position].id != id else { throw .duplicateSource(id) }
        guard entries.count < policy.maximumSources else { throw .sourceTableFull(capacity: policy.maximumSources) }
        let follower: MIDIClockFollower
        do {
            follower = try MIDIClockFollower()
        } catch {
            throw .clock(error)
        }
        entries.insert(Entry(id: id, follower: follower), at: position)
    }

    /// Unregisters a non-leader source.
    mutating func removeSource(_ id: MIDIInputID) throws(MIDIClockArbitrationError) {
        guard let index = index(of: id) else { throw .unknownSource(id) }
        guard leader != .external(id) else { throw .sourceIsLeader(id) }
        entries.remove(at: index)
    }

    /// Explicitly selects the transport's clock authority. A new external leader gets a fresh follower whose
    /// next Continue resumes at `position` (ignored for `.internal`), starts acquiring with no tempo, and every
    /// source's ignored counts restart.
    mutating func selectLeader(_ selected: MIDIClockLeader,
                               resumingAt position: Int64 = 0) throws(MIDIClockArbitrationError)
        -> MIDIClockLeaderChange {
        guard selected != leader else { throw .alreadySelected(selected) }
        let follower: MIDIClockFollower
        let fresh: MIDIClockTempoEstimator
        do {
            follower = try MIDIClockFollower(position: position)
            fresh = try MIDIClockTempoEstimator(timebase: timebase)
        } catch {
            throw .clock(error)
        }
        var selectedIndex: Int?
        if case let .external(id) = selected {
            guard let index = index(of: id) else { throw .unknownSource(id) }
            selectedIndex = index
        }
        let change = MIDIClockLeaderChange(previous: leader, selected: selected)
        if let selectedIndex { entries[selectedIndex].follower = follower }
        for index in entries.indices { entries[index].ignored = MIDIClockIgnoredCounts() }
        leader = selected
        lock = .acquiring
        run = SteadyRun()
        estimator = fresh
        tempo = nil
        return change
    }

    /// Applies one message from source `id` at `host`. Only the selected leader's messages reach the
    /// transport; any other source's are counted and reported once per kind.
    mutating func receive(_ message: MIDIClockMessage, from id: MIDIInputID,
                          at host: HostStamp) throws(MIDIClockArbitrationError) -> [MIDIClockArbitrationEvent] {
        guard let index = index(of: id) else { throw .unknownSource(id) }
        var entry = entries[index]
        if let lastHost = entry.lastHost, host.ticks < lastHost.ticks {
            throw .nonMonotonicHost(source: id, previous: lastHost.ticks, current: host.ticks)
        }
        let followerEvent: MIDIClockFollowerEvent?
        do {
            followerEvent = try entry.follower.receive(message, at: host)
        } catch {
            throw .clock(error)
        }
        entry.lastHost = host
        guard leader == .external(id) else {
            let first = entry.ignored.record(MIDIClockMessageKind(message))
            entries[index] = entry
            return first ? [.competingSource(id, MIDIClockMessageKind(message), .notLeader(selected: leader))] : []
        }
        var events: [MIDIClockArbitrationEvent] = []
        if message == .clock {
            var estimator = self.estimator
            do {
                _ = try estimator.observePulse(at: host)
            } catch {
                throw .clock(error)
            }
            self.estimator = estimator
            if let lost = observeLeaderPulse(id, at: host) { events.append(lost) }
        }
        entries[index] = entry
        if let followerEvent { events.append(.transport(followerEvent)) }
        if message == .clock, let locked = lockIfSteady(id) { events.append(locked) }
        return events
    }

    /// Reports the leader lost when no leader pulse arrived for longer than the timeout. A silent leader
    /// that is still acquiring or already lost restarts its steady count without an event.
    mutating func poll(now: HostStamp) throws(MIDIClockArbitrationError) -> MIDIClockArbitrationEvent? {
        if let lastPoll, now.ticks < lastPoll.ticks {
            throw .nonMonotonicPoll(previous: lastPoll.ticks, current: now.ticks)
        }
        guard case let .external(id) = leader, let index = index(of: id) else {
            lastPoll = now
            return nil
        }
        if let lastHost = entries[index].lastHost, now.ticks < lastHost.ticks {
            throw .nonMonotonicPoll(previous: lastHost.ticks, current: now.ticks)
        }
        lastPoll = now
        guard let lastPulse = run.lastPulse, now.ticks - lastPulse.ticks > timeoutTicks else { return nil }
        run = SteadyRun()
        guard lock == .locked else { return nil }
        let reason = MIDIClockDegradedReason.silence(lastPulse: lastPulse, detectedAt: now)
        lock = .lost(reason)
        return .leaderLost(id, reason: reason, heldTempo: tempo)
    }

    /// Advances the steady run; a gap past the timeout restarts it and loses a locked leader.
    private mutating func observeLeaderPulse(_ id: MIDIInputID, at host: HostStamp) -> MIDIClockArbitrationEvent? {
        guard let lastPulse = run.lastPulse, host.ticks - lastPulse.ticks > timeoutTicks else {
            run.advance(to: host, tolerancePerMille: policy.jitterTolerancePerMille, cap: policy.reacquirePulses)
            return nil
        }
        run = SteadyRun(lastPulse: host)
        guard lock == .locked else { return nil }
        let reason = MIDIClockDegradedReason.lateArrival(lastPulse: lastPulse, detectedAt: host)
        lock = .lost(reason)
        return .leaderLost(id, reason: reason, heldTempo: tempo)
    }

    /// Locks after N steady pulses and, while locked, keeps the latest tempo estimate.
    private mutating func lockIfSteady(_ id: MIDIInputID) -> MIDIClockArbitrationEvent? {
        if lock == .locked {
            if let estimate = estimator.estimate { tempo = estimate }
            return nil
        }
        guard run.steadyPulses >= policy.reacquirePulses else { return nil }
        let reacquired = lock != .acquiring
        lock = .locked
        if let estimate = estimator.estimate { tempo = estimate }
        return .leaderLocked(id, tempo: tempo, reacquired: reacquired)
    }

    private func index(of id: MIDIInputID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    private func snapshot(_ entry: Entry) -> MIDIClockSourceStatus {
        MIDIClockSourceStatus(id: entry.id, isLeader: leader == .external(entry.id),
                              followerState: entry.follower.state, nextPulseTicks: entry.follower.nextPulseTicks,
                              lastHost: entry.lastHost, ignored: entry.ignored)
    }
}
