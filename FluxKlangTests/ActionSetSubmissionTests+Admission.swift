import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// What changed between `decide` and `submit`: readiness, transport, an undeclared counter (#107 A2).
@Suite("Action-set submit-time readiness and requirement checks", .productionAccessAudit)
struct ActionSetSubmissionAdmissionTests {
    private typealias Harness = ActionSetSubmissionHarness

    /// Decided while every member was ready; member 1 then became unprepared with no ledger bump.
    @Test
    func memberUnpreparedAfterDecideDropsTheWholeSetAndReservesNothing() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let decision = try harness.decide(resolved)
        let stamps = try Harness.stamps(decision)
        try harness.fixture.readiness.transition(harness.ids[1], to: .unprepared)
        let before = try harness.snapshot()
        let submission = try harness.submit(decision, of: resolved)
        let report = ActionSetReadinessAggregate.evaluate(resolved, readiness: harness.fixture.readiness,
                                                          ledger: harness.fixture.ledger)
        #expect(submission == .dropped(ActionSetDropReport(set: resolved.set.id, reason: .notReady,
                                                           readiness: report)))
        #expect(report.state == .unprepared && report.notReady.map(\.action) == [harness.ids[1]])
        #expect(try harness.snapshot() == before)
        // No trigger ID was consumed: every stamp is still admissible into a copy of the scheduler.
        var copy = harness.scheduler
        for stamp in stamps {
            _ = try copy.submit(stamp, session: copy.currentToken, context: harness.context)
        }
        // Once the member is ready again, the same decision fires whole (into a copy of everything).
        var ready = harness
        try ready.fixture.ready([harness.ids[1]])
        guard case .fired(let record) = try ready.submit(decision, of: resolved) else {
            Issue.record("A ready set must fire")
            return
        }
        #expect(record.handles.map(\.trigger) == stamps.map(\.id) && ready.pending.count == 3)
        // Staleness is checked before readiness: a stale requirement refuses even a set that would drop.
        try harness.fixture.ledger.bump(ActionSetFixture.context, reason: .contextChange)
        let bumped = try harness.snapshot()
        let stale = Harness.refusal { () throws(ActionSetSubmitRefusal) in try harness.submit(decision, of: resolved) }
        guard case .staleRequirement(index: 0, ActionSetFixture.context) = stale else {
            Issue.record("Expected staleRequirement(0, context), got \(String(describing: stale))")
            return
        }
        #expect(try harness.snapshot() == bumped)
    }

    /// The check is `ActionReadiness.isCurrent`, not the bare `ready` state: a member prepared against a
    /// source that has since been superseded (a source its stamp does not carry) drops the whole set.
    @Test
    func memberPreparedAgainstASupersededSourceDropsAtSubmit() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        try harness.fixture.readiness.transition(harness.ids[2], to: .unprepared)
        try harness.fixture.ready([harness.ids[2]], against: harness.fixture.sources(1))
        let decision = try harness.decide(resolved)
        _ = try Harness.stamps(decision)
        try harness.fixture.ledger.bump(ActionSetFixture.sourceKeys[0], reason: .sourceLost)
        #expect(harness.fixture.readiness.state(harness.ids[2]) == .ready)
        let before = try harness.snapshot()
        guard case .dropped(let report) = try harness.submit(decision, of: resolved) else {
            Issue.record("A member prepared against a superseded source must drop the set")
            return
        }
        #expect(report.set == resolved.set.id && report.reason == .notReady && report.readiness.state == .invalidated)
        #expect(report.readiness.notReady.map(\.action) == [harness.ids[2]])
        #expect(report.readiness.members[2].reason == .sourceChanged)
        #expect(try harness.snapshot() == before)
    }

    /// A locate between decide and submit supersedes the transport generation of a musical target.
    @Test
    func locateBetweenDecideAndSubmitRefusesAMusicalSetAsStale() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let transport = GenerationKey(.transport, ActionSetFixture.musical)
        let decision = try harness.decide(resolved, target: .grid(ticks: 960))
        let stamps = try Harness.stamps(decision)
        #expect(stamps.allSatisfy { stamp in stamp.requires.contains { $0.key == transport } })
        try harness.fixture.ledger.bump(transport, reason: .locate(ticks: 1_920))
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(decision, of: resolved)
        }
        guard case .staleRequirement(index: 0, transport) = refusal else {
            Issue.record("Expected staleRequirement(0, transport), got \(String(describing: refusal))")
            return
        }
        #expect(refusal?.memberIndex == 0 && refusal?.underlyingError == nil)
        #expect(try harness.snapshot() == before)
    }

    /// A counter the submit ledger never declared is its own refusal; once declared and bumped, it is stale.
    @Test
    func undeclaredRequirementIsRefusedDistinctlyFromAStaleOne() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let stamps = try harness.stamps(resolved)
        let undeclared = GenerationKey(kind: .source, subject: GenerationSubject(validated: "source.undeclared"))
        #expect(harness.fixture.ledger.generation(undeclared) == nil)
        let forged = Harness.replacing(stamps[1], requires: stamps[1].requires + [
            GenerationRequirement(key: undeclared, generation: .initial)
        ])
        let fire = ActionSetFireDecision.fire([stamps[0], forged, stamps[2]])
        // A stale session would refuse at the scheduler; the requirement check comes first.
        let staleToken = harness.scheduler.currentToken
        _ = try harness.scheduler.rotateSession(expected: staleToken)
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(fire, of: resolved, token: staleToken)
        }
        guard case .undeclaredRequirement(index: 1, undeclared) = refusal else {
            Issue.record("Expected undeclaredRequirement(1), got \(String(describing: refusal))")
            return
        }
        #expect(refusal?.memberIndex == 1 && refusal?.underlyingError == nil)
        #expect(try harness.snapshot() == before)
        try harness.fixture.ledger.declare(undeclared)
        try harness.fixture.ledger.bump(undeclared, reason: .sourceLost)
        let stale = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(fire, of: resolved, token: staleToken)
        }
        guard case .staleRequirement(index: 1, undeclared) = stale else {
            Issue.record("Expected staleRequirement(1), got \(String(describing: stale))")
            return
        }
        // Member order, then requirement order: a stale member 0 wins over an undeclared member 1.
        let decided = try harness.stamps(resolved)
        try harness.fixture.ledger.bump(ActionSetFixture.context, reason: .contextChange)
        let fresh = try harness.stamps(resolved)
        let later = GenerationKey(kind: .source, subject: GenerationSubject(validated: "source.undeclared.later"))
        let mixed = ActionSetFireDecision.fire([decided[0], Harness.replacing(fresh[1], requires: fresh[1].requires + [
            GenerationRequirement(key: later, generation: .initial)
        ]), fresh[2]])
        let mixedBefore = try harness.snapshot()
        let first = Harness.refusal { () throws(ActionSetSubmitRefusal) in try harness.submit(mixed, of: resolved) }
        guard case .staleRequirement(index: 0, ActionSetFixture.context) = first else {
            Issue.record("Expected staleRequirement(0, context), got \(String(describing: first))")
            return
        }
        #expect(try harness.snapshot() == mixedBefore)
    }

    /// Precedence in both directions: the first failing requirement in member order wins whatever its kind,
    /// and within one member the first failing requirement in requirement order wins.
    @Test
    func requirementRefusalFollowsMemberOrderThenRequirementOrder() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let decided = try harness.stamps(resolved)
        try harness.fixture.ledger.bump(ActionSetFixture.context, reason: .contextChange)
        let fresh = try harness.stamps(resolved)
        let undeclared = GenerationKey(kind: .source, subject: GenerationSubject(validated: "source.undeclared"))
        let missing = [GenerationRequirement(key: undeclared, generation: .initial)]
        let before = try harness.snapshot()
        // An undeclared member 0 wins over a stale member 1.
        let mirror = ActionSetFireDecision.fire([Harness.replacing(fresh[0], requires: fresh[0].requires + missing),
                                                 decided[1], fresh[2]])
        let first = Harness.refusal { () throws(ActionSetSubmitRefusal) in try harness.submit(mirror, of: resolved) }
        guard case .undeclaredRequirement(index: 0, undeclared) = first else {
            Issue.record("Expected undeclaredRequirement(0), got \(String(describing: first))")
            return
        }
        #expect(try harness.snapshot() == before)
        // One member listing a stale requirement before an undeclared one reports the stale one.
        #expect(decided[1].requires.contains { $0.key == ActionSetFixture.context })
        let within = ActionSetFireDecision.fire([fresh[0], Harness.replacing(decided[1],
                                                                              requires: decided[1].requires + missing),
                                                 fresh[2]])
        let inner = Harness.refusal { () throws(ActionSetSubmitRefusal) in try harness.submit(within, of: resolved) }
        guard case .staleRequirement(index: 1, ActionSetFixture.context) = inner else {
            Issue.record("Expected staleRequirement(1, context), got \(String(describing: inner))")
            return
        }
        #expect(try harness.snapshot() == before)
        // Reversing the requirements within that member reports the undeclared requirement first.
        let reversedRequirements = missing + decided[1].requires
        let reversedWithin = ActionSetFireDecision.fire([
            fresh[0],
            Harness.replacing(decided[1], requires: reversedRequirements),
            fresh[2]
        ])
        let reversed = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(reversedWithin, of: resolved)
        }
        guard case .undeclaredRequirement(index: 1, let key) = reversed, key == undeclared else {
            Issue.record(
                "Expected undeclaredRequirement(1, \(undeclared)), got \(String(describing: reversed))"
            )
            return
        }
        #expect(try harness.snapshot() == before)
    }
}
