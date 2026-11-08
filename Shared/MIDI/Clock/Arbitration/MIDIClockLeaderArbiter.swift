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
//  Lock: the leader locks after N steady pulses (the policy's
//  `reacquirePulses`), each judged against a stable reference period by
//  `MIDIClockSteadyRun`. Once locked, estimator jitter never unlocks. The status tempo is
//  the C1 estimator's current estimate, read live, so it follows the estimator
//  and is nil (pending) whenever the estimator has none, including on a relock.
//  The estimator's own lock transitions are reported as `leaderTempo` and never
//  bump: the arbiter owns the leader's source generation.
//
//  Silence: no leader message of any kind since its selection for strictly
//  longer than the timeout, seen when the next message arrives or by
//  `poll(now:)`, restarts the steady run and the estimator (a locked estimator
//  reports `leaderTempo(.lost)` first, even if its own dropout is longer than
//  the timeout). While the leader's follower transport runs (armed or running)
//  silence is a loss: a locked, acquiring or idle leader reports exactly one
//  `leaderLost` (`.sourceLost`) per episode, the transport holds the last
//  tempo estimated during the lock (nil if none, whatever the poll cadence),
//  and N steady pulses relock it (`.sourceReacquired`). While the transport is
//  stopped, silence is not a loss: a locked or acquiring leader reports `leaderIdle`,
//  claims no tempo and bumps nothing; its next clock starts a fresh steady run,
//  and a relock from idle bumps nothing either. Leader clocks stamped before
//  the latest poll that found the leader silent were queued behind that
//  silence: they reach the follower but are only counted (`stalePulses`), so
//  they cannot relock a leader that poll already ended. Nothing ever switches
//  the leader automatically; `selectLeader` is the only way.
//
//  Time is caller-supplied host stamps; there is no timer or wall clock. Each
//  source's stamps and the poll stamps must not go back. Every throwing call
//  leaves the arbiter unchanged: refusals are checked, and the follower runs
//  on a copy, before anything is stored. The estimator only sees the leader's
//  ordered stamps and polls no earlier than its last message, so its own
//  refusals are unreachable (and it throws before mutating).
//
//  Per-message cost (control side, not the render thread): a linear search of
//  at most 64 sources, a copy of one scalar follower, the estimator's period
//  while acquiring, and an events array that allocates only when non-empty.
//  The estimator and the ignored counters are mutated in place, so a pulse
//  never copies the estimator's timestamp ring; a selection or silence installs
//  a fresh estimator sharing a template's ring, which its first pulse copies.
//
//  Jitter: with a `jitterWatch`, each source keeps its last clock stamps and its status reports their arrival
//  jitter. It is reported only: no decision above reads it. A message refused as an unknown source, as
//  non-monotonic or by the follower records nothing. An accepted clock writes one stamp: once the window is full it
//  overwrites the oldest slot in place (an unverified performance claim: no test or mutant can tell an in-place
//  update from a read, modify and write back), and while it fills it appends. The report is built when a status is
//  read.
//

struct MIDIClockLeaderArbiter: Sendable {
    /// The selected leader's phase between selections.
    private enum Phase: Equatable, Sendable {
        /// Counting steady pulses; the cause is what the eventual `leaderLocked` reports.
        case acquiring(MIDIClockLockCause)
        case locked
        /// Lost while running and not relocked; the loss was bumped.
        case lost(MIDIClockDegradedReason, heldTempo: MIDIClockTempoEstimate?)
        /// Silent while stopped; the next clock starts acquiring with the same cause.
        case idle(MIDIClockLockCause)
    }

    private struct Entry: Sendable {
        let id: MIDIInputID
        var follower: MIDIClockFollower
        var lastHost: HostStamp?
        var ignored = MIDIClockIgnoredCounts()
        var window: MIDIClockStampWindow?
    }

    let policy: MIDIClockArbitrationPolicy
    let timebase: HostTimebase
    /// Set at init: when present every source reports its jitter.
    let jitterWatch: MIDIClockJitterWatch?
    /// The policy timeout rounded up to whole host ticks.
    let timeoutTicks: UInt64
    private(set) var leader = MIDIClockLeader.internal
    /// Leader clocks stamped before the latest silent poll since the selection: counted, never reacquiring.
    private(set) var stalePulses: UInt64 = 0
    /// Sorted by source ID.
    private var entries: [Entry] = []
    private var phase = Phase.acquiring(.selection)
    private var run = MIDIClockSteadyRun()
    private var estimator: MIDIClockTempoEstimator
    /// An unused estimator whose copies restart the leader's estimate without a throwing init.
    private let freshEstimator: MIDIClockTempoEstimator
    /// The leader's last message since its selection: silence is measured from here.
    private var leaderLastMessage: HostStamp?
    /// The last tempo the estimator reported during the current lock; `leaderLost` holds it, whatever the poll
    /// cadence. Reset on selection, idle and each new lock.
    private var lastLockedTempo: MIDIClockTempoEstimate?
    /// The latest poll that found the leader silent past the timeout, since the selection.
    private var silencePoll: HostStamp?
    private var lastPoll: HostStamp?

    init(policy: MIDIClockArbitrationPolicy = .standard,
         timebase: HostTimebase,
         jitterWatch: MIDIClockJitterWatch? = nil) throws(MIDIClockArbitrationError) {
        do {
            freshEstimator = try MIDIClockTempoEstimator(timebase: timebase)
        } catch {
            throw .clock(error)
        }
        estimator = freshEstimator
        self.policy = policy
        self.timebase = timebase
        self.jitterWatch = jitterWatch
        let ticks = ExactMath.ceilDiv(Int128(policy.timeoutNanos) * Int128(timebase.denom), Int128(timebase.numer))
        timeoutTicks = UInt64(ticks)
    }

    /// The leader and its phase, including the degraded reason and held tempo.
    var status: MIDIClockLeaderStatus {
        guard case let .external(id) = leader else { return .internal }
        switch phase {
        case .acquiring: return .acquiring(id, steadyPulses: run.steadyPulses)
        case .locked: return .locked(id, tempo: estimator.estimate)
        case let .lost(reason, heldTempo):
            return .degraded(id, reason: reason, heldTempo: heldTempo, steadyPulses: run.steadyPulses)
        case .idle: return .idle(id)
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
        let window = jitterWatch.map { MIDIClockStampWindow(watch: $0) }
        entries.insert(Entry(id: id, follower: follower, window: window), at: position)
    }

    /// Unregisters a non-leader source.
    mutating func removeSource(_ id: MIDIInputID) throws(MIDIClockArbitrationError) {
        guard let index = index(of: id) else { throw .unknownSource(id) }
        guard leader != .external(id) else { throw .sourceIsLeader(id) }
        entries.remove(at: index)
    }

    /// Explicitly selects the transport's clock authority. A new external leader gets a fresh, stopped follower
    /// whose next Continue resumes at `position`; for `.internal` the position is ignored and not validated. The
    /// new leader starts acquiring with no tempo, and every source's ignored and stale counts restart.
    ///
    /// Switching while the transport runs sends no synthetic Stop: the old leader's messages simply stop
    /// reaching the transport, and the transport generation bumps when the new leader's Start, Continue or
    /// Song Position Pointer reports one. The change's `.sourceLost` is for the previous authority's source
    /// counter: `source/<previous MIDIInputID>`, or for `.internal` the counter the consumer keeps for its
    /// internal clock. It is nil when the previous leader's loss was already bumped by `leaderLost` and it
    /// never relocked, so one loss episode never bumps twice.
    mutating func selectLeader(_ selected: MIDIClockLeader,
                               resumingAt position: Int64 = 0) throws(MIDIClockArbitrationError)
        -> MIDIClockLeaderChange {
        guard selected != leader else { throw .alreadySelected(selected) }
        let alreadyBumped = if case .lost = phase { true } else { false }
        let change = MIDIClockLeaderChange(previous: leader, selected: selected,
                                           bumpReason: alreadyBumped ? nil : .sourceLost)
        if case let .external(id) = selected {
            guard let index = index(of: id) else { throw .unknownSource(id) }
            do {
                entries[index].follower = try MIDIClockFollower(position: position)
            } catch {
                throw .clock(error)
            }
        }
        for index in entries.indices { entries[index].ignored = MIDIClockIgnoredCounts() }
        leader = selected
        phase = .acquiring(.selection)
        run = MIDIClockSteadyRun()
        estimator = freshEstimator
        leaderLastMessage = nil
        lastLockedTempo = nil
        silencePoll = nil
        stalePulses = 0
        return change
    }

    /// Applies one message from source `id` at `host`. Only the selected leader's messages reach the
    /// transport; any other source's are counted and reported once per kind.
    mutating func receive(_ message: MIDIClockMessage, from id: MIDIInputID,
                          at host: HostStamp) throws(MIDIClockArbitrationError) -> [MIDIClockArbitrationEvent] {
        guard let index = index(of: id) else { throw .unknownSource(id) }
        if let lastHost = entries[index].lastHost, host.ticks < lastHost.ticks {
            throw .nonMonotonicHost(source: id, previous: lastHost.ticks, current: host.ticks)
        }
        var follower = entries[index].follower
        let wasRunning = follower.state != .stopped
        let followerEvent: MIDIClockFollowerEvent?
        do {
            followerEvent = try follower.receive(message, at: host)
        } catch {
            throw .clock(error)
        }
        entries[index].follower = follower
        entries[index].lastHost = host
        recordJitter(message, at: index, host)
        guard leader == .external(id) else {
            let kind = MIDIClockMessageKind(message)
            guard entries[index].ignored.record(kind) else { return [] }
            return [.competingSource(id, kind, .notLeader(selected: leader))]
        }
        var events: [MIDIClockArbitrationEvent] = []
        if let last = leaderLastMessage, host.ticks - last.ticks > timeoutTicks {
            let reason = MIDIClockDegradedReason.lateArrival(lastMessage: last, detectedAt: host)
            events = try silence(id, reason, running: wasRunning, at: host)
        }
        leaderLastMessage = host
        if let followerEvent { events.append(.transport(followerEvent)) }
        if message == .clock { events += try observeLeaderPulse(id, at: host) }
        return events
    }

    /// Reports a leader silent for longer than the timeout as lost (transport running) or idle (stopped), and
    /// otherwise forwards the poll to the estimator, whose own dropout makes the tempo pending.
    mutating func poll(now: HostStamp) throws(MIDIClockArbitrationError) -> [MIDIClockArbitrationEvent] {
        if let lastPoll, now.ticks < lastPoll.ticks {
            throw .nonMonotonicPoll(previous: lastPoll.ticks, current: now.ticks)
        }
        guard case let .external(id) = leader, let index = index(of: id) else {
            lastPoll = now
            return []
        }
        if let lastHost = entries[index].lastHost, now.ticks < lastHost.ticks {
            throw .nonMonotonicPoll(previous: lastHost.ticks, current: now.ticks)
        }
        guard let last = leaderLastMessage, now.ticks - last.ticks > timeoutTicks else {
            let event = try pollEstimator(now)
            lastPoll = now
            return event.map { [.leaderTempo(id, $0)] } ?? []
        }
        let reason = MIDIClockDegradedReason.silence(lastMessage: last, detectedAt: now)
        let events = try silence(id, reason, running: entries[index].follower.state != .stopped, at: now)
        lastPoll = now
        silencePoll = now
        return events
    }

    /// Ends a silence: the estimator reports its own dropout, then it and the steady run restart. A running
    /// transport loses the leader (once per episode); a stopped one idles a locked or acquiring leader. A locked
    /// estimator whose dropout outlasts this silence still reports `.lost`, so its next lock is never a second
    /// `.acquired` without one between.
    private mutating func silence(_ id: MIDIInputID, _ reason: MIDIClockDegradedReason, running: Bool,
                                  at now: HostStamp) throws(MIDIClockArbitrationError) -> [MIDIClockArbitrationEvent] {
        let heldTempo = phase == .locked ? lastLockedTempo : nil
        var events: [MIDIClockArbitrationEvent] = []
        if let event = try pollEstimator(now) {
            events.append(.leaderTempo(id, event))
        } else if estimator.lock == .locked, let lastPulse = estimator.lastPulse {
            events.append(.leaderTempo(id, .lost(lastPulse: lastPulse)))
        }
        estimator = freshEstimator
        run = MIDIClockSteadyRun()
        switch phase {
        case .lost:
            break
        case .idle where !running:
            break
        case .locked where !running:
            phase = .idle(.idle)
            lastLockedTempo = nil
            events.append(.leaderIdle(id, reason: reason))
        case let .acquiring(cause) where !running:
            phase = .idle(cause)
            lastLockedTempo = nil
            events.append(.leaderIdle(id, reason: reason))
        case .locked, .acquiring, .idle:
            phase = .lost(reason, heldTempo: heldTempo)
            events.append(.leaderLost(id, reason: reason, heldTempo: heldTempo))
        }
        return events
    }

    /// Feeds a leader clock to the estimator and, until locked, the steady run; N steady pulses lock it.
    private mutating func observeLeaderPulse(_ id: MIDIInputID,
                                             at host: HostStamp) throws(MIDIClockArbitrationError)
        -> [MIDIClockArbitrationEvent] {
        if let silencePoll, host.ticks < silencePoll.ticks {
            if stalePulses < .max { stalePulses += 1 }
            return []
        }
        var events: [MIDIClockArbitrationEvent] = []
        do {
            if let event = try estimator.observePulse(at: host) { events.append(.leaderTempo(id, event)) }
        } catch {
            throw .clock(error)
        }
        let cause: MIDIClockLockCause
        switch phase {
        case .locked:
            if let estimate = estimator.estimate { lastLockedTempo = estimate }
            return events
        case let .acquiring(acquiring): cause = acquiring
        case .lost: cause = .loss
        case let .idle(idle):
            cause = idle
            phase = .acquiring(idle)
        }
        run.advance(to: host, seed: estimatorPeriod, tolerancePerMille: policy.jitterTolerancePerMille,
                    cap: policy.reacquirePulses)
        guard run.steadyPulses >= policy.reacquirePulses else { return events }
        phase = .locked
        lastLockedTempo = estimator.estimate
        events.append(.leaderLocked(id, tempo: estimator.estimate, after: cause))
        return events
    }

    private mutating func pollEstimator(_ now: HostStamp) throws(MIDIClockArbitrationError) -> MIDIClockLockEvent? {
        do {
            return try estimator.poll(now: now)
        } catch {
            throw .clock(error)
        }
    }

    /// The estimator's per-pulse period, which seeds a steady run's reference. A clamped estimate does not
    /// measure the pulses, so it seeds nothing.
    private var estimatorPeriod: MIDIClockSteadyRun.Period? {
        guard let estimate = estimator.estimate, !estimate.clamped else { return nil }
        return MIDIClockSteadyRun.Period(span: Int128(estimate.microsPerQuarter) * 1_000 * Int128(timebase.denom),
                                         pulses: Int128(MIDIClockMath.pulsesPerQuarter) * Int128(timebase.numer))
    }

    private func index(of id: MIDIInputID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    private func snapshot(_ entry: Entry) -> MIDIClockSourceStatus {
        MIDIClockSourceStatus(id: entry.id, isLeader: leader == .external(entry.id),
                              followerState: entry.follower.state, nextPulseTicks: entry.follower.nextPulseTicks,
                              lastHost: entry.lastHost, ignored: entry.ignored, jitter: jitterReport(entry))
    }

    /// Mutates the window in place, to avoid copying the ring per message (an unverified performance claim: no test
    /// or mutant can tell an in-place update from a read, modify and write back).
    private mutating func recordJitter(_ message: MIDIClockMessage, at index: Int, _ host: HostStamp) {
        guard message == .clock else { return }
        entries[index].window?.record(host)
    }

    private func jitterReport(_ entry: Entry) -> MIDIClockSourceJitter? {
        guard let watch = jitterWatch, let window = entry.window else { return nil }
        return MIDIClockSourceJitter.report(window: window, watch: watch)
    }
}
