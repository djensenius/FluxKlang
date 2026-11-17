import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// #190 K-ACKMC: the state machine of the acknowledgement-handshake interleaving model; the rules, scenarios and
// checks are in `RealtimeHandoffTests+AckHandshakeModel.swift`. Not a weak-memory proof; not RT-certified.

/// The model's shared locations: the critical scope's `FaultLatch` tally word, the epoch of each cycle's
/// `KernelAckRequests` and its private `KernelCycle.lastFaultedAckEpoch` (cycle 1, then its replacement, cycle 2,
/// whose epochs restart at 0), and the one telemetry slot both cycles publish to.
enum AckLocation: Int, CaseIterable {
    case latch, epoch1, epoch2, lastFaulted1, lastFaulted2, slot

    static func epoch(_ cycle: Int) -> Self { cycle == 1 ? .epoch1 : .epoch2 }
    static func lastFaulted(_ cycle: Int) -> Self { cycle == 1 ? .lastFaulted1 : .lastFaulted2 }
}

/// The raiser (a producer whose `noteOff` was refused), control, render, and an optional forger: trusted control
/// code holding the `TelemetrySlots` that publishes into the cycle's slot, breaking its single producer.
enum AckThread: Int, CaseIterable { case producer, control, render, forger }

/// One 4-bit modification-order index per location: the newest write a thread has observed there, or what an
/// acquiring read of a release makes visible.
struct AckView: Hashable {
    private var bits: UInt32 = 0

    subscript(_ location: AckLocation) -> Int {
        get { Int(bits >> UInt32(location.rawValue * 4) & 0xF) }
        set {
            let shift = UInt32(location.rawValue * 4)
            bits = bits & ~(0xF << shift) | UInt32(newValue) << shift
        }
    }

    func merged(_ other: Self) -> Self {
        var result = self
        for location in AckLocation.allCases { result[location] = max(self[location], other[location]) }
        return result
    }
}

/// One write: its value and the view an acquiring read of it takes on (the writer's view at its release; a
/// read-modify-write also carries its predecessor's, continuing that write's release sequence).
struct AckEntry: Hashable {
    let value: Int
    let view: AckView
}

/// The `FaultLatch` tally word, reduced to `generation << 4 | count`: latched while `count > 0`.
enum AckLatch {
    static func isLatched(_ word: Int) -> Bool { word & 0xF > 0 }
    static func rearmed(_ word: Int) -> Int { (word >> 4 + 1) << 4 }
}

/// A telemetry sample's handshake fields, packed `cycle << 8 | ackEpochSeen << 4 | lastFaultedAckEpoch`. Cycle 0 is
/// the empty slot: `latestTelemetry()` is `nil` before the first publish, so nothing approves.
struct AckSample: CustomStringConvertible {
    let cycle: Int
    let seen: Int
    let lastFaulted: Int

    init(cycle: Int, seen: Int, lastFaulted: Int) {
        (self.cycle, self.seen, self.lastFaulted) = (cycle, seen, lastFaulted)
    }

    init(word: Int) { self.init(cycle: word >> 8, seen: word >> 4 & 0xF, lastFaulted: word & 0xF) }

    var word: Int { cycle << 8 | seen << 4 | lastFaulted }
    var description: String { "(ackCycle \(cycle), ackEpochSeen \(seen), lastFaultedAckEpoch \(lastFaulted))" }
}

/// A model ticket: the issuing cycle and the epoch its request published.
struct AckTicketModel: Hashable {
    let cycle: Int
    let epoch: Int
    var approved = false
    /// This ticket's first stale refusal in this schedule, if any (see `AckStaleRead`).
    var staleRefusal: AckStaleRead?
}

/// A refusal caused by stale telemetry, not by waiting: control read slot entry `index` (`sample`, which the
/// production predicate refuses) while a newer entry, `newerApproving`, that the predicate approves already existed
/// in the slot's modification order, and the private `lastFaultedAckEpoch` it then read already reached the
/// ticket's epoch. Only the older sample explains the refusal.
struct AckStaleRead: Hashable {
    let sample: Int
    let index: Int
    let newerApproving: Int
}

/// What one render cycle did: its cycle, the epoch it loaded, and the latch entry it read.
struct AckCycleRecord: Hashable, CustomStringConvertible {
    let cycle: Int
    let epoch: Int
    let latchEntry: Int
    let latched: Bool

    var description: String {
        "cycle \(cycle) loaded epoch \(epoch), read latch entry \(latchEntry), latched \(latched)"
    }
}

/// One search: the scenario, the rules and the production tickets every approval decision goes through.
struct AckContext {
    let scenario: AckScenario
    let rules: AckRules
    let production: AckProductionTickets
}

/// One approval decision that said yes: the ticket (its `staleRefusal` is set when this schedule refused it on stale
/// telemetry earlier), whether a covering cycle exists (see `AckState.covers`), and the trace for a counterexample.
struct AckApproval {
    let ticket: AckTicketModel
    let covered: Bool
    let trace: String
}

enum AckRenderStep: Hashable { case idle, reading, storing, publishing }
enum AckControlStep: Hashable {
    case observe, request, poll, check(ticket: Int, sample: Int, stale: AckStaleRead?), acknowledge, done
}

/// One reachable state of the handshake: every location's modification order (a history of entries), each thread's
/// view, and each thread's program position. Render runs cycles of `renderCycle` (with a replacement, cycle 2 after
/// cycle 1), each: load the epoch (acquire), read the latch (acquire), on a latched read store the private
/// `lastFaultedAckEpoch` (release), publish the sample (release). Control observes (acquire), requests (a releasing
/// compare-exchange), checks a ticket by reading the slot then the private atomic (both acquire) and, after an
/// approval, acknowledges (an acquire-release compare-exchange on the tally word, as `FaultLatch.acknowledge`). The
/// producer raises (an acquire-release add on the tally word). A refused check polls the same ticket again: that
/// shows only that approval is reachable in the model. Production consumes the ticket and retries with a new request
/// and epoch, which is not modelled, so this says nothing about production retry liveness.
struct AckState: Hashable {
    var history: [[AckEntry]] = AckLocation.allCases.map { _ in [AckEntry(value: 0, view: AckView())] }
    var views = [AckView](repeating: AckView(), count: AckThread.allCases.count)
    var raisesLeft: Int
    var forgeriesLeft: Int
    var renderStep = AckRenderStep.idle
    var renderCycle = 1
    var cyclesLeft: Int
    var loadedEpoch = 0
    var latchEntry = 0
    /// The rendering cycle's own `KernelCycleTelemetry.lastFaultedAckEpoch` (its cumulative counters).
    var publishedLastFaulted = 0
    var cycles: [AckCycleRecord] = []
    var controlStep: AckControlStep
    var roundsLeft: Int
    /// The latch entry the current round observed.
    var observed = 0
    var tickets: [AckTicketModel] = []

    init(_ scenario: AckScenario, _ rules: AckRules) {
        raisesLeft = scenario.raises
        forgeriesLeft = rules.forgedSample ? 1 : 0
        cyclesLeft = scenario.renderCycles
        roundsLeft = scenario.rounds
        controlStep = rules.requestBeforeObserve ? .request : .observe
    }

    /// Every coherent read of `location` by `thread`: each entry from the thread's own floor to the latest (the read
    /// moves the floor there). An acquiring read also takes on the entry's view.
    func reads(_ location: AckLocation, by thread: AckThread, acquire: Bool = true) -> [(value: Int, state: Self)] {
        let entries = history[location.rawValue]
        return (views[thread.rawValue][location]..<entries.count).map { index in
            var next = self
            next.views[thread.rawValue][location] = index
            if acquire { next.views[thread.rawValue] = next.views[thread.rawValue].merged(entries[index].view) }
            return (entries[index].value, next)
        }
    }

    /// A releasing store, newest in `location`'s modification order.
    mutating func store(_ value: Int, at location: AckLocation, by thread: AckThread) {
        views[thread.rawValue][location] = history[location.rawValue].count
        history[location.rawValue].append(AckEntry(value: value, view: views[thread.rawValue]))
    }

    /// A releasing read-modify-write of the latest entry (nothing comes between its read and its write); `update`
    /// returns `nil` for a failed compare-exchange. Returns the value written, or `nil`.
    @discardableResult
    mutating func readModifyWrite(_ location: AckLocation, by thread: AckThread, acquire: Bool,
                                  _ update: (Int) -> Int?) -> Int? {
        let latest = history[location.rawValue][history[location.rawValue].count - 1]
        views[thread.rawValue][location] = history[location.rawValue].count - 1
        if acquire { views[thread.rawValue] = views[thread.rawValue].merged(latest.view) }
        guard let value = update(latest.value) else { return nil }
        views[thread.rawValue][location] = history[location.rawValue].count
        history[location.rawValue].append(AckEntry(value: value, view: views[thread.rawValue].merged(latest.view)))
        return value
    }

    /// The safety property, read off the trace: `true` when a cycle of `ticket`'s identity loaded its epoch or a
    /// later one (so after its request's increment) and then read the latch latched at the observed entry or later.
    /// That cycle armed the flush watermark after the observed raise, so the `noteOn` queued before that raise's
    /// refused `noteOff` is discarded, never sounded.
    func covers(_ ticket: AckTicketModel) -> Bool {
        cycles.contains {
            $0.cycle == ticket.cycle && $0.epoch >= ticket.epoch && $0.latched && $0.latchEntry >= observed
        }
    }
}

// MARK: Steps

extension AckState {
    /// Every state one step of one thread reaches, with the approval that step made, if any.
    func successors(_ context: AckContext) -> [(state: Self, approval: AckApproval?)] {
        var next: [(state: Self, approval: AckApproval?)] = []
        if raisesLeft > 0 {
            var raised = self
            raised.raisesLeft -= 1
            raised.readModifyWrite(.latch, by: .producer, acquire: true) { $0 + 1 }
            next.append((raised, nil))
        }
        if forgeriesLeft > 0 {
            var forged = self
            forged.forgeriesLeft -= 1
            forged.store(AckSample(cycle: 1, seen: 2, lastFaulted: 2).word, at: .slot, by: .forger)
            next.append((forged, nil))
        }
        next += renderSteps(context).map { ($0, nil) }
        next += controlSteps(context)
        return next
    }

    private func renderSteps(_ context: AckContext) -> [Self] {
        let (scenario, rules) = (context.scenario, context.rules)
        switch renderStep {
        case .idle:
            guard cyclesLeft > 0 else { return [] }
            var steps = (rules.latchBeforeEpoch ? readLatch() : loadEpoch(rules)).map { state in
                var state = state
                state.renderStep = .reading
                return state
            }
            if scenario.replaces, renderCycle == 1, cyclesLeft < scenario.renderCycles {
                var replaced = self
                (replaced.renderCycle, replaced.publishedLastFaulted) = (2, 0)
                steps.append(replaced)
            }
            return steps
        case .reading:
            return (rules.latchBeforeEpoch ? loadEpoch(rules) : readLatch()).map { state in
                var state = state
                let latched = AckLatch.isLatched(history[AckLocation.latch.rawValue][state.latchEntry].value)
                state.cycles.append(AckCycleRecord(cycle: renderCycle, epoch: state.loadedEpoch,
                                                   latchEntry: state.latchEntry, latched: latched))
                state.renderStep = latched || rules.faultedEpochOnEveryCycle ? .storing : .publishing
                return state
            }
        case .storing:
            var stored = self
            stored.store(loadedEpoch, at: .lastFaulted(renderCycle), by: .render)
            (stored.publishedLastFaulted, stored.renderStep) = (loadedEpoch, .publishing)
            return [stored]
        case .publishing:
            var published = self
            let sample = AckSample(cycle: renderCycle, seen: loadedEpoch, lastFaulted: publishedLastFaulted)
            published.store(sample.word, at: .slot, by: .render)
            (published.cyclesLeft, published.renderStep) = (cyclesLeft - 1, .idle)
            return [published]
        }
    }

    private func loadEpoch(_ rules: AckRules) -> [Self] {
        reads(.epoch(renderCycle), by: .render, acquire: !rules.relaxedEpochLoad).map { read in
            var state = read.state
            state.loadedEpoch = read.value
            return state
        }
    }

    private func readLatch() -> [Self] {
        reads(.latch, by: .render).map { read in
            var state = read.state
            state.latchEntry = state.views[AckThread.render.rawValue][.latch]
            return state
        }
    }

    private func controlSteps(_ context: AckContext) -> [(state: Self, approval: AckApproval?)] {
        let (scenario, rules) = (context.scenario, context.rules)
        switch controlStep {
        case .observe:
            return reads(.latch, by: .control).map { read in
                var state = read.state
                if AckLatch.isLatched(read.value) {
                    state.observed = state.views[AckThread.control.rawValue][.latch]
                    state.controlStep = rules.requestBeforeObserve ? .poll : .request
                }
                return (state, nil)
            }
        case .request:
            var requested = self
            let cycle = scenario.requestCycles[tickets.count]
            let epoch = requested.readModifyWrite(.epoch(cycle), by: .control, acquire: false) { $0 + 1 } ?? 0
            requested.tickets.append(AckTicketModel(cycle: cycle, epoch: epoch))
            if requested.tickets.count == scenario.requestCycles.count {
                requested.controlStep = rules.requestBeforeObserve ? .observe : .poll
            }
            return [(requested, nil)]
        case .poll:
            return tickets.indices.filter { !tickets[$0].approved }.flatMap { ticket in
                reads(.slot, by: .control).map { read in
                    var state = read.state
                    let stale = staleRead(read.value, at: state.views[AckThread.control.rawValue][.slot],
                                          tickets[ticket], context)
                    state.controlStep = .check(ticket: ticket, sample: read.value, stale: stale)
                    return (state, nil)
                }
            }
        case let .check(ticket, sample, stale):
            return reads(.lastFaulted(tickets[ticket].cycle), by: .control).map { read in
                read.state.checked(ticket, AckSample(word: sample), read.value, stale, context)
            }
        case .acknowledge:
            var acknowledged = self
            let expected = history[AckLocation.latch.rawValue][observed].value
            acknowledged.readModifyWrite(.latch, by: .control, acquire: true) {
                $0 == expected ? AckLatch.rearmed($0) : nil
            }
            acknowledged.nextRound(rules)
            return [(acknowledged, nil)]
        case .done:
            return []
        }
    }

    /// The production predicate (`KernelCycleTelemetry.permitsAcknowledgement(_:)`) on `sample`; the empty slot
    /// (`latestTelemetry()` is `nil`) never approves.
    private func permits(_ sample: AckSample, _ ticket: AckTicketModel, _ context: AckContext) -> Bool {
        let stamp = context.rules.identityIgnored && sample.cycle != 0 ? ticket.cycle : sample.cycle
        return sample.cycle != 0 && context.production.permits(sample, stamp: stamp, ticket)
    }

    /// For a slot read of entry `index`: the stale read, when that sample is refused and a newer entry in the slot's
    /// modification order (already written, so not a later publication) is approved by the production predicate.
    private func staleRead(_ word: Int, at index: Int, _ ticket: AckTicketModel,
                           _ context: AckContext) -> AckStaleRead? {
        let slot = history[AckLocation.slot.rawValue]
        guard !permits(AckSample(word: word), ticket, context) else { return nil }
        let newer = slot.indices.dropFirst(index + 1).first {
            permits(AckSample(word: slot[$0].value), ticket, context)
        }
        return newer.map { AckStaleRead(sample: word, index: index, newerApproving: $0) }
    }

    /// `acknowledgeCritical`'s approval: the production predicate on the slot's sample, then (unless the rules drop
    /// it) the same `>=` on the private atomic. A refusal on a stale read whose private atomic already reached the
    /// epoch is recorded on the ticket (its first one), so a later approval in this schedule is a stale delay.
    private func checked(_ index: Int, _ sample: AckSample, _ lastFaulted: Int, _ stale: AckStaleRead?,
                         _ context: AckContext) -> (state: Self, approval: AckApproval?) {
        var state = self
        let ticket = tickets[index]
        let permitted = permits(sample, ticket, context)
        guard permitted, context.rules.sampleOnly || lastFaulted >= ticket.epoch else {
            if let stale, lastFaulted >= ticket.epoch, ticket.staleRefusal == nil {
                state.tickets[index].staleRefusal = stale
            }
            state.controlStep = .poll
            return (state, nil)
        }
        let trace = "cycle \(ticket.cycle) epoch \(ticket.epoch) for latch entry \(observed) approved on sample "
            + "\(sample) and private \(lastFaulted); render: \(cycles)"
        let approval = AckApproval(ticket: ticket, covered: covers(ticket), trace: trace)
        state.tickets[index].approved = true
        if context.scenario.acknowledges {
            state.controlStep = .acknowledge
        } else {
            state.controlStep = state.tickets.allSatisfy(\.approved) ? .done : .poll
        }
        return (state, approval)
    }

    /// After an acknowledgement attempt (re-armed, or refused by a re-raise): the next round, if any.
    private mutating func nextRound(_ rules: AckRules) {
        roundsLeft -= 1
        (tickets, observed) = ([], 0)
        controlStep = roundsLeft == 0 ? .done : rules.requestBeforeObserve ? .request : .observe
    }

    /// Every state reachable from the start, depth-first; a state reached twice is expanded once.
    static func explore(_ scenario: AckScenario, _ production: AckProductionTickets,
                        _ rules: AckRules = AckRules()) -> AckExploration {
        let context = AckContext(scenario: scenario, rules: rules, production: production)
        let start = Self(scenario, rules)
        var seen: Set<Self> = [start]
        var pending = [start]
        var result = AckExploration()
        while let state = pending.popLast() {
            for (next, approval) in state.successors(context) {
                if let approval { result.note(approval) }
                if seen.insert(next).inserted { pending.append(next) }
            }
        }
        result.states = seen.count
        return result
    }
}
