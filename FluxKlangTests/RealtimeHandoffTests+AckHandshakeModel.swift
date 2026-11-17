import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// #190 K-ACKMC: an exhaustive, reduced interleaving model of the kernel-cycle fault-acknowledgement handshake
// (`KernelAckRequests`, `KernelCycle.run` step 0 and step 7, `KernelCycle.acknowledgeCritical`). Not a weak-memory
// proof; not RT-certified.

/// The handshake as built, or with one part broken (the negative controls).
struct AckRules {
    /// Render reads `isLatched` before it loads the epoch (step 0 after step 2).
    var latchBeforeEpoch = false
    /// Control requests its epochs before `observe`, then binds them to that later observation.
    var requestBeforeObserve = false
    /// Render's epoch load is relaxed, so it makes nothing before the request visible.
    var relaxedEpochLoad = false
    /// Render stores and publishes `lastFaultedAckEpoch` on every cycle, faulted or not.
    var faultedEpochOnEveryCycle = false
    /// A forger publishes `(cycle 1, seen 2, lastFaulted 2)` into the slot once, at any point.
    var forgedSample = false
    /// Approval on the sample alone, without the private `lastFaultedAckEpoch` check.
    var sampleOnly = false
    /// The sample is stamped with the ticket's cycle before the predicate, as if it ignored `ackCycle`.
    var identityIgnored = false
}

/// What runs: how often the producer raises, how many observe-request-approve rounds control makes (each
/// requesting on `requestCycles`), whether it acknowledges, and whether render replaces cycle 1 with cycle 2.
struct AckScenario {
    let raises: Int
    let rounds: Int
    let requestCycles: [Int]
    let acknowledges: Bool
    let replaces: Bool
    let renderCycles = 3

    /// Two raises (a re-raise while latched, or a second fault after an acknowledgement) and two sequential rounds
    /// on one cycle: a re-raise refuses the round's acknowledgement, so the second round requests epoch 2.
    static let reRaise = Self(raises: 2, rounds: 2, requestCycles: [1], acknowledges: true, replaces: false)
    /// One raise; control requests on cycle 1 and on its replacement, cycle 2 (a fresh identity whose epochs
    /// restart at 0, on the same slot), and checks both tickets until each is approved. Render replaces cycle 1
    /// after at least one of its cycles.
    static let replacement = Self(raises: 1, rounds: 1, requestCycles: [1, 2], acknowledges: false, replaces: true)
}

/// Real `KernelAckTicket`s for the model's tickets (cycle 1 or 2, epoch 1 or 2), from two `KernelAckRequests` on one
/// test latch, so every approval calls the production `KernelCycleTelemetry.permitsAcknowledgement(_:)`. Tickets
/// come only from `request(for:)`, the narrowest test-visible path; the model maps its cycles to their identities.
final class AckProductionTickets {
    private struct SetupError: Error {}

    /// Index 0 is the empty slot's `ackCycle`; 1 and 2 are the two cycles' identities.
    let identities: [UInt64]
    private let first1: KernelAckTicket
    private let first2: KernelAckTicket
    private let replacement1: KernelAckTicket
    private let replacement2: KernelAckTicket

    init() throws {
        let faults = try FaultChainAuthority.testing(scopes: [CycleRig.criticalScope])
        guard faults.raise(CycleRig.criticalScope, .criticalExhausted, frame: 0) == .ok,
              let observation = faults.observe(CycleRig.criticalScope),
              let first = KernelAckRequests(faults: faults, criticalScope: CycleRig.criticalScope),
              let replacement = KernelAckRequests(faults: faults, criticalScope: CycleRig.criticalScope)
        else { throw SetupError() }
        identities = [0, first.identity, replacement.identity]
        first1 = try first.request(for: observation)
        first2 = try first.request(for: observation)
        replacement1 = try replacement.request(for: observation)
        replacement2 = try replacement.request(for: observation)
    }

    /// The production predicate for model ticket `ticket` on `sample`, stamped with `stamp`'s identity.
    func permits(_ sample: AckSample, stamp: Int, _ ticket: AckTicketModel) -> Bool {
        let telemetry = KernelCycleTelemetry(ackEpochSeen: UInt64(sample.seen),
                                             lastFaultedAckEpoch: UInt64(sample.lastFaulted),
                                             ackCycle: identities[stamp])
        switch (ticket.cycle, ticket.epoch) {
        case (1, 1): return telemetry.permitsAcknowledgement(first1)
        case (1, 2): return telemetry.permitsAcknowledgement(first2)
        case (2, 1): return telemetry.permitsAcknowledgement(replacement1)
        case (2, 2): return telemetry.permitsAcknowledgement(replacement2)
        default:
            Issue.record("no production ticket for \(ticket)")
            return false
        }
    }
}

/// What the exhaustive search found over every reachable state.
struct AckExploration {
    var states = 0
    /// `[cycle, epoch]` of every ticket some schedule approved.
    var approved: Set<[Int]> = []
    /// `[cycle, epoch]` of every ticket some schedule refused on stale telemetry (`AckStaleRead`) and then approved,
    /// in that same schedule, with the first such stale read found.
    var delayed: [[Int]: AckStaleRead] = [:]
    /// The first stale delay found, as a trace.
    var delayWitness: String?
    /// The first approval with no covering cycle.
    var counterexample: String?

    mutating func note(_ approval: AckApproval) {
        let key = [approval.ticket.cycle, approval.ticket.epoch]
        approved.insert(key)
        if let stale = approval.ticket.staleRefusal, delayed[key] == nil {
            delayed[key] = stale
            delayWitness = delayWitness ?? "refused on slot entry \(stale.index) \(AckSample(word: stale.sample)) "
                + "while entry \(stale.newerApproving) approved it, private atomic at the epoch; then \(approval.trace)"
        }
        if !approval.covered, counterexample == nil { counterexample = approval.trace }
    }
}

// MARK: Checks

extension RealtimeHandoffTests {
    /// Exhaustive, reduced-bound evidence for the acknowledgement handshake on `KernelAckRequests` (its four-step
    /// happens-before chain) and `KernelCycle.acknowledgeCritical`. It is an interleaving model, not a C11
    /// weak-memory proof and not RT certification. It explores every interleaving of a producer (raises), control
    /// (observe, request, check, acknowledge) and render (3 cycles; in one scenario, cycle 1 then its replacement on
    /// the same telemetry slot), in which every read may return any coherent value: not older, per location, than a
    /// value the reading thread has already observed. Release/acquire is modelled as visibility: once an acquiring
    /// read sees a releasing write, everything the writer had observed before it is visible to the reader. The
    /// model has no load buffering or out-of-thin-air values, appends each write at the end of its location's
    /// modification order, and checks at most 2 raises, 2 requests and 3 render cycles. Approval calls the
    /// production `KernelCycleTelemetry.permitsAcknowledgement(_:)` on real tickets, then the same `>=` on the private
    /// atomic as `acknowledgeCritical`; the model's own code is the rest (`AckState`). Safety is read off each
    /// execution's trace (`AckState.covers`), not re-derived from the predicate.
    ///
    /// Control's refused checks poll the same ticket again until it is approved, so "every ticket is approved in some
    /// schedule" is model-level existential reachability only. Production `acknowledgeCritical` consumes the ticket,
    /// and control retries with a new request and epoch, which these scenarios do not model: this is not evidence of
    /// production retry liveness or of eventual acknowledgement.
    struct AckHandshakeBound {
        /// Production handshake: every approval follows a cycle of the ticket's identity that loaded its epoch or a
        /// later one, then read the latch latched at the observed raise or later; every ticket is approved in some
        /// schedule (epoch 2 after a re-raise refuses round 1's acknowledgement; the replacement's ticket); and every
        /// ticket is, in some schedule, refused on stale telemetry (an older sample read while a newer approving one
        /// already existed and the private atomic already reached the epoch) and then approved in that schedule.
        @Test func everyApprovalFollowsACoveringFaultedCycle() throws {
            let production = try AckProductionTickets()
            let reRaise = AckState.explore(.reRaise, production)
            let replacement = AckState.explore(.replacement, production)
            for run in [reRaise, replacement] {
                #expect(run.counterexample == nil, "\(run.counterexample ?? "")")
                #expect(run.delayed.values.allSatisfy { $0.index < $0.newerApproving })
                #expect(run.delayWitness != nil)
            }
            #expect(reRaise.approved == [[1, 1], [1, 2]] && replacement.approved == [[1, 1], [2, 1]])
            #expect(Set(reRaise.delayed.keys) == reRaise.approved, "\(reRaise.delayed)")
            #expect(Set(replacement.delayed.keys) == replacement.approved, "\(replacement.delayed)")
        }

        /// With the slot's single producer kept, the production predicate alone is already safe, including after a
        /// replacement (whose epochs restart at 0) on the same slot: `ackCycle` keeps the replacement's samples from
        /// approving the replaced cycle's ticket. The private atomic is the defence against a forged sample.
        @Test func sampleAloneIsSafeWithASingleProducer() throws {
            let production = try AckProductionTickets()
            for scenario in [AckScenario.reRaise, .replacement] {
                let run = AckState.explore(scenario, production, AckRules(sampleOnly: true))
                #expect(run.counterexample == nil, "\(run.counterexample ?? "")")
            }
        }

        /// A sample forged into the slot (`(ackCycle 1, ackEpochSeen 2, lastFaultedAckEpoch 2)`, published at any
        /// point) can only withhold or delay approval while the private atomic is checked; on the sample alone it
        /// approves a ticket no faulted cycle covers. So the private check is necessary against forgery.
        @Test func forgedSampleOnlyDelaysWithThePrivateCheck() throws {
            let production = try AckProductionTickets()
            let checked = AckState.explore(.reRaise, production, AckRules(forgedSample: true))
            #expect(checked.counterexample == nil, "\(checked.counterexample ?? "")")
            #expect(checked.approved == [[1, 1], [1, 2]])
            let sampleOnly = AckState.explore(.reRaise, production, AckRules(forgedSample: true, sampleOnly: true))
            #expect(sampleOnly.counterexample != nil)
        }

        /// Negative control: render reads the latch before it loads the epoch. A cycle reads the latch, the producer
        /// re-raises, control observes and requests, then the cycle loads that epoch and stores it as faulted: the
        /// ticket is approved though no cycle read the latch at the observed raise.
        @Test func latchReadBeforeEpochLoadApprovesUncoveredTicket() throws {
            let run = AckState.explore(.reRaise, try AckProductionTickets(), AckRules(latchBeforeEpoch: true))
            #expect(run.counterexample != nil)
        }

        /// Negative control: control requests before it observes, then binds the ticket to the later observation. A
        /// cycle loads the epoch and reads the latch at the first raise; the producer re-raises; control observes
        /// the re-raise and the ticket is approved on that cycle, which never saw it.
        @Test func requestBeforeObserveApprovesUncoveredTicket() throws {
            let run = AckState.explore(.reRaise, try AckProductionTickets(), AckRules(requestBeforeObserve: true))
            #expect(run.counterexample != nil)
        }

        /// Negative control: render's epoch load is relaxed. A cycle loads the requested epoch without taking on
        /// control's view, so it can still read the latch at the first raise after control observed the re-raise.
        @Test func relaxedEpochLoadApprovesUncoveredTicket() throws {
            let run = AckState.explore(.reRaise, try AckProductionTickets(), AckRules(relaxedEpochLoad: true))
            #expect(run.counterexample != nil)
        }

        /// Negative control: approval ignores `ackCycle` and the private atomic. The replacement's faulted cycle
        /// publishes `lastFaultedAckEpoch` 1 for its own ticket, and the replaced cycle's epoch-1 ticket, which no
        /// cycle of its own covers, is approved on it. With the private atomic checked, ignoring `ackCycle` alone
        /// stays safe: only the replaced cycle's own faulted runs store its atomic.
        @Test func identityIgnoredApprovesReplacedCycleTicket() throws {
            let production = try AckProductionTickets()
            let sampleOnly = AckState.explore(.replacement, production,
                                              AckRules(sampleOnly: true, identityIgnored: true))
            #expect(sampleOnly.counterexample != nil)
            let checked = AckState.explore(.replacement, production, AckRules(identityIgnored: true))
            #expect(checked.counterexample == nil, "\(checked.counterexample ?? "")")
        }
    }
}
