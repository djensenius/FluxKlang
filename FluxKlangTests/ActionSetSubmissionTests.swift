import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Real scheduler, real registry and the A1 fixture's fake readiness provider (#107 A2).
struct ActionSetSubmissionHarness {
    /// Thrown by a helper after it records the issue, so the calling test stops.
    private enum HarnessError: Error {
        case notFired, notFire
    }

    /// Every observable piece of state a refused submission must leave unchanged.
    struct Snapshot: Equatable {
        let token: TriggerSessionToken
        let schedulerPending: Int
        let reserved: Int
        let musical: SchedulerMusicalSummary?
        let clock: SchedulerClock.Snapshot
        let queued: [SessionOutcome]
        let counters: [GenerationKey: Generation]
        let registryCount: Int
        let registryScopes: [[TriggerID]]
    }

    static let sceneKey = GenerationKey(kind: .cancelScope, subject: ActionSetFixture.scene)
    static let otherKey = GenerationKey(kind: .cancelScope, subject: ActionSetFixture.other)

    var fixture: ActionSetFixture
    var scheduler: TriggerScheduler
    var pending = ActionSetPendingTriggers()
    let ids: [ActionID]
    let scopes: [GenerationSubject]

    init(members: Int = 3, capacity: Int = 64,
         scopes: [GenerationSubject] = [ActionSetFixture.scene, ActionSetFixture.other]) throws {
        fixture = try ActionSetFixture(scopes: scopes)
        ids = try ActionSetFixture.ids(members)
        self.scopes = scopes
        try fixture.ready(ids)
        scheduler = try TriggerScheduler(ledger: fixture.ledger, timebase: ActionSetFixture.timebase,
                                         outcomeCapacity: capacity)
    }

    var context: TriggerSchedulerContext {
        TriggerSchedulerContext(ledger: fixture.ledger, readiness: fixture.readiness, musicalSequence: nil)
    }

    var submitContext: ActionSetSubmitContext {
        ActionSetSubmitContext(session: scheduler.currentToken, scheduler: context)
    }

    func resolved(_ members: [ActionID]? = nil, set: String = "set.a",
                  scope: GenerationSubject = ActionSetFixture.scene) throws -> ResolvedActionSet {
        try ActionSetFixture.resolved(members ?? ids, set: set, scope: scope)
    }

    func decide(_ resolved: ResolvedActionSet, _ base: String = "trg.fire", target: TriggerTarget = .asap,
                extra: [ActionID: [GenerationRequirement]] = [:]) throws -> ActionSetFireDecision {
        try fixture.decide(resolved, ActionSetFixture.request(base, target: target, extra: extra))
    }

    func stamps(_ resolved: ResolvedActionSet, _ base: String = "trg.fire",
                target: TriggerTarget = .asap) throws -> [TriggerStamp] {
        try ActionSetSubmissionHarness.stamps(decide(resolved, base, target: target))
    }

    mutating func submit(_ decision: ActionSetFireDecision, of resolved: ResolvedActionSet,
                         token: TriggerSessionToken? = nil,
                         context: TriggerSchedulerContext? = nil) throws(ActionSetSubmitRefusal)
        -> ActionSetSubmission {
        let claim = ActionSetSubmitContext(session: token ?? scheduler.currentToken, scheduler: context ?? self.context)
        return try ActionSetSubmitter.submit(decision, of: resolved, context: claim, scheduler: &scheduler,
                                             pending: &pending)
    }

    mutating func fire(_ resolved: ResolvedActionSet, _ base: String = "trg.fire") throws -> ActionSetFireRecord {
        let submission = try ActionSetSubmitter.fire(resolved, request: ActionSetFixture.request(base),
                                                     context: submitContext, scheduler: &scheduler,
                                                     pending: &pending)
        guard case .fired(let record) = submission else {
            Issue.record("Expected a fired record, got \(submission)")
            throw HarnessError.notFired
        }
        return record
    }

    mutating func cancel(_ scope: GenerationSubject) throws(ActionSetSubmitRefusal) -> [TriggerHandle] {
        try ActionSetSubmitter.userCancel(scope: scope, ledger: &fixture.ledger, scheduler: &scheduler,
                                          pending: &pending)
    }

    /// Settles against the live scheduler the outcomes were drained from.
    @discardableResult
    mutating func settle(_ outcomes: [SessionOutcome]) -> [TriggerID] {
        ActionSetSubmitter.settle(outcomes, scheduler: scheduler, pending: &pending)
    }

    /// Registers stamps of throwaway fires straight into the registry until it holds `count`.
    mutating func fillRegistry(_ count: Int) throws {
        let all = try ActionSetFixture.ids(16, prefix: "fill")
        try fixture.ready(all)
        var fire = 0
        while pending.count < count {
            let stamps = try stamps(resolved(all), "trg.fill.\(fire)")
            try pending.register(Array(stamps.prefix(count - pending.count)), ledger: fixture.ledger)
            fire += 1
        }
    }

    mutating func observe() throws {
        let generation = try #require(fixture.ledger.generation(fixture.ledger.primaryClock))
        let sample = SampleStamp(clock: ActionSetFixture.primary, generation: generation, frame: 0)
        try scheduler.observe(ClockAnchor(sample: sample, host: HostStamp(ticks: 0)),
                              nominalRate: fixture.ledger.nominalRate, timebase: ActionSetFixture.timebase,
                              ledger: fixture.ledger)
    }

    func snapshot() throws -> Snapshot {
        var copy = scheduler
        return Snapshot(token: scheduler.currentToken, schedulerPending: scheduler.pendingCount,
                        reserved: scheduler.reservedOutcomeCount, musical: scheduler.musicalSummary,
                        clock: try scheduler.snapshot(ledger: fixture.ledger), queued: copy.drain(),
                        counters: fixture.ledger.current, registryCount: pending.count,
                        registryScopes: scopes.map(pending.pending(in:)))
    }

    /// The stamps of a fire decision; a drop is recorded as an issue.
    static func stamps(_ decision: ActionSetFireDecision) throws -> [TriggerStamp] {
        guard case .fire(let stamps) = decision else {
            Issue.record("Expected a fire decision, got \(decision)")
            throw HarnessError.notFire
        }
        return stamps
    }

    /// The same stamp with other requirements.
    static func replacing(_ stamp: TriggerStamp, requires: [GenerationRequirement]) -> TriggerStamp {
        TriggerStamp(id: stamp.id, action: stamp.action, originHost: stamp.originHost,
                     horizonFrame: stamp.horizonFrame, requires: requires, target: stamp.target,
                     latePolicy: stamp.latePolicy, retroactiveMs: stamp.retroactiveMs,
                     stoppedPolicy: stamp.stoppedPolicy, loopIteration: stamp.loopIteration)
    }

    /// The refusal a body throws, or nil (recorded as an issue) when it does not throw.
    static func refusal<T>(_ body: () throws(ActionSetSubmitRefusal) -> T) -> ActionSetSubmitRefusal? {
        do {
            _ = try body()
        } catch {
            return error
        }
        Issue.record("Expected an ActionSetSubmitRefusal")
        return nil
    }
}

@Suite("Action-set atomic submission")
struct ActionSetSubmissionTests {
    private typealias Harness = ActionSetSubmissionHarness

    @Test(arguments: [1, 3, 16])
    func readySetAdmitsEveryMemberInMemberOrder(count: Int) throws {
        var harness = try Harness(members: count)
        try harness.fixture.ledger.bump(ActionSetSubmissionHarness.sceneKey, reason: .userCancel)
        let order = Array(harness.ids.reversed())
        let resolved = try harness.resolved(order)
        let record = try harness.fire(resolved)
        let scope = try harness.fixture.current(ActionSetSubmissionHarness.sceneKey)
        #expect(record.set == resolved.set.id && record.cancelScope == scope && scope.generation.value == 2)
        #expect(record.members.map(\.action) == order)
        #expect(record.handles.map(\.trigger.rawValue) == (0..<count).map { "trg.fire.\($0)" })
        #expect(record.handles.allSatisfy { $0.session == harness.scheduler.currentToken })
        #expect(harness.scheduler.pendingCount == count && harness.scheduler.reservedOutcomeCount == count)
        #expect(harness.pending.count == count)
        #expect(harness.pending.pending(in: ActionSetFixture.scene) == record.handles.map(\.trigger).sorted())
        var copy = harness.scheduler
        #expect(copy.drain().isEmpty)
    }

    @Test
    func submitOfADecisionMatchesFire() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let decision = try harness.decide(resolved)
        let stamps = try ActionSetSubmissionHarness.stamps(decision)
        guard case .fired(let record) = try harness.submit(decision, of: resolved) else {
            Issue.record("A ready decision must fire")
            return
        }
        #expect(record.members.map(\.action) == stamps.map(\.action))
        #expect(record.handles.map(\.trigger) == stamps.map(\.id))
        for handle in record.handles {
            #expect(harness.scheduler.pendingMusic(handle) == nil)
        }
        #expect(harness.scheduler.pendingCount == 3 && harness.pending.count == 3)
    }

    @Test
    func droppedDecisionSubmitsNothingAndReturnsTheReportUnchanged() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        try harness.fixture.readiness.transition(harness.ids[1], to: .invalidated)
        let decision = try harness.decide(resolved)
        guard case .dropped(let report) = decision else {
            Issue.record("A not-ready set must drop")
            return
        }
        let before = try harness.snapshot()
        #expect(try harness.submit(decision, of: resolved) == .dropped(report))
        let viaFire = try ActionSetSubmitter.fire(resolved, request: ActionSetFixture.request(),
                                                  context: harness.submitContext, scheduler: &harness.scheduler,
                                                  pending: &harness.pending)
        #expect(viaFire == .dropped(report))
        #expect(try harness.snapshot() == before)
        let foreign = try harness.resolved(set: "set.other")
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in try harness.submit(decision, of: foreign) }
        guard case .setMismatch(let expected, let actual) = refusal else {
            Issue.record("Expected setMismatch, got \(String(describing: refusal))")
            return
        }
        #expect(expected == foreign.set.id && actual == resolved.set.id)
        #expect(try harness.snapshot() == before)
    }

    /// A refusal at member k publishes nothing: no handle, no consumed ID, no registry entry. Every member is
    /// ready in the submit snapshot, so the members before k pass every check and are staged first.
    @Test(arguments: ActionSetSubmissionSchedulerCase.allCases)
    func schedulerRefusalAtMemberLeavesEverythingUnchanged(scenario: ActionSetSubmissionSchedulerCase) throws {
        var harness = try Harness(capacity: scenario == .outcomeCapacity ? 2 : 64)
        let resolved = try harness.resolved()
        var stamps = try harness.stamps(resolved, target: scenario == .musicalFirst ? .grid(ticks: 960) : .asap)
        let token = harness.scheduler.currentToken
        let context = harness.context
        switch scenario {
        case .staleSession:
            _ = try harness.scheduler.rotateSession(expected: token)
        case .duplicateID, .duplicateLast:
            _ = try harness.scheduler.submit(stamps[scenario.index], session: token, context: context)
        case .musicalLast:
            // Only the last member is musical, so only it needs the (unprepared) musical timeline.
            stamps[2] = try harness.stamps(resolved, target: .grid(ticks: 960))[2]
        case .outcomeCapacity, .musicalFirst:
            break
        }
        #expect(stamps.allSatisfy { context.readiness.isCurrent($0.action, ledger: context.ledger) })
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(.fire(stamps), of: resolved, token: token, context: context)
        }
        #expect(refusal?.memberIndex == scenario.index)
        guard case .scheduler(let index, let error) = refusal else {
            Issue.record("Expected a scheduler refusal, got \(String(describing: refusal))")
            return
        }
        #expect(index == scenario.index)
        #expect(scenario.matches(error), "unexpected underlying error \(error)")
        #expect(refusal.map { $0.underlyingError != nil } == true)
        #expect(try harness.snapshot() == before)
        // Members before k consumed no identity: each is still admissible into a copy.
        var copy = harness.scheduler
        for stamp in stamps.prefix(scenario.index) {
            _ = try copy.submit(stamp, session: copy.currentToken, context: context)
        }
    }

    @Test
    func registryCapacityIsCheckedAtTheBoundaryBeforeAnySchedulerSubmit() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        try harness.fillRegistry(ActionSetPendingTriggers.maximumPending - 2)
        let decision = try harness.decide(resolved)
        // A stale session would refuse at the scheduler; capacity must win first.
        let staleToken = harness.scheduler.currentToken
        _ = try harness.scheduler.rotateSession(expected: staleToken)
        let before = try harness.snapshot()
        let full = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(decision, of: resolved, token: staleToken)
        }
        guard case .pendingCapacity(let pendingCount, let requested) = full else {
            Issue.record("Expected pendingCapacity, got \(String(describing: full))")
            return
        }
        #expect(pendingCount == 254 && requested == 3 && full?.memberIndex == nil)
        #expect(try harness.snapshot() == before)
        // N: 253 registered plus 3 members is exactly 256.
        let freed = harness.pending.complete(TriggerID(validated: "trg.fill.15.13"))
        #expect(freed && harness.pending.count == 253)
        let record = try harness.fire(resolved)
        #expect(harness.pending.count == 256 && record.handles.count == 3)
    }

    @Test
    func shapeRefusalsNameTheMemberBeforeAnyOtherCheck() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let stamps = try harness.stamps(resolved)
        // A stale session would refuse at the scheduler; the shape check must win first.
        let staleToken = harness.scheduler.currentToken
        _ = try harness.scheduler.rotateSession(expected: staleToken)
        let twoScopes = try Harness.replacing(stamps[1], requires: stamps[1].requires + [
            harness.fixture.current(ActionSetSubmissionHarness.otherKey)
        ])
        let before = try harness.snapshot()
        let cases: [([TriggerStamp], ActionSetSubmitRefusal)] = [
            (Array(stamps.prefix(2)), .memberCount(expected: 3, actual: 2)),
            ([], .memberCount(expected: 3, actual: 0)),
            ([stamps[0], stamps[2], stamps[1]], .memberMismatch(index: 1)),
            ([stamps[0], twoScopes, stamps[2]], .memberMismatch(index: 1)),
            (try harness.stamps(harness.resolved(scope: ActionSetFixture.other)), .memberMismatch(index: 0))
        ]
        for (fire, expected) in cases {
            let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
                try harness.submit(.fire(fire), of: resolved, token: staleToken)
            }
            #expect(String(describing: refusal) == String(describing: Optional(expected)))
            #expect(try harness.snapshot() == before)
        }
        // A later member stamped against another cancel-scope generation is not part of this fire.
        try harness.fixture.ledger.bump(ActionSetSubmissionHarness.sceneKey, reason: .userCancel)
        let mixed = try [stamps[0], stamps[1], harness.stamps(resolved, "trg.fire")[2]]
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(.fire(mixed), of: resolved)
        }
        guard case .memberMismatch(index: 2) = refusal else {
            Issue.record("Expected memberMismatch(2), got \(String(describing: refusal))")
            return
        }
    }

    @Test
    func requirementStaleSinceDecideIsRefusedAtItsMember() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let source = ActionSetFixture.sourceKeys[1]
        let decision = try harness.decide(resolved, extra: [
            harness.ids[0]: harness.fixture.sources(1), harness.ids[2]: harness.fixture.sources(2)
        ])
        try harness.fixture.ledger.bump(source, reason: .sourceLost)
        // A stale session would refuse at the scheduler; the staleness check comes first.
        let staleToken = harness.scheduler.currentToken
        _ = try harness.scheduler.rotateSession(expected: staleToken)
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(decision, of: resolved, token: staleToken)
        }
        guard case .staleRequirement(index: 2, let key) = refusal else {
            Issue.record("Expected staleRequirement(2), got \(String(describing: refusal))")
            return
        }
        #expect(key == source && refusal?.memberIndex == 2)
        #expect(try harness.snapshot() == before)
        try harness.fixture.ledger.bump(ActionSetFixture.context, reason: .contextChange)
        let first = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(decision, of: resolved)
        }
        guard case .staleRequirement(index: 0, ActionSetFixture.context) = first else {
            Issue.record("Expected staleRequirement(0, context), got \(String(describing: first))")
            return
        }
    }

    @Test
    func registryRefusalNamesTheMemberAndPublishesNothing() throws {
        var harness = try Harness()
        let resolved = try harness.resolved()
        let decision = try harness.decide(resolved)
        let stamps = try ActionSetSubmissionHarness.stamps(decision)
        try harness.pending.register(stamps[1], ledger: harness.fixture.ledger)
        // A stale session would refuse at the scheduler; registry staging comes first.
        let staleToken = harness.scheduler.currentToken
        _ = try harness.scheduler.rotateSession(expected: staleToken)
        let before = try harness.snapshot()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try harness.submit(decision, of: resolved, token: staleToken)
        }
        guard case .registry(index: 1, .duplicatePending(let id)) = refusal else {
            Issue.record("Expected registry(1, duplicatePending), got \(String(describing: refusal))")
            return
        }
        #expect(id == stamps[1].id && refusal?.underlyingError == nil)
        #expect(try harness.snapshot() == before)
    }

    @Test
    func builderRefusalSurfacesAsDecision() throws {
        var harness = try Harness(members: 1)
        let before = try harness.snapshot()
        let subject = GenerationSubject(validated: "scope.unknown")
        let unknown = try harness.resolved(scope: subject)
        let request = try ActionSetFixture.request()
        let refusal = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try ActionSetSubmitter.fire(unknown, request: request, context: harness.submitContext,
                                        scheduler: &harness.scheduler, pending: &harness.pending)
        }
        let key = GenerationKey(kind: .cancelScope, subject: subject)
        guard case .decision(.undeclaredCounter(key)) = refusal else {
            Issue.record("Expected decision(undeclaredCounter), got \(String(describing: refusal))")
            return
        }
        #expect(refusal?.memberIndex == nil && refusal?.underlyingError == nil)
        #expect(try harness.snapshot() == before)
    }

    @Test
    func recordFactoryRefusesHandlesThatDoNotMatchTheStamps() throws {
        var harness = try Harness(members: 2)
        let resolved = try harness.resolved()
        let record = try harness.fire(resolved)
        let stamps = try harness.stamps(resolved)
        let swapped = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try ActionSetFireRecord.make(set: resolved.set, stamps: stamps, handles: Array(record.handles.reversed()))
        }
        #expect(String(describing: swapped) == String(describing: Optional(ActionSetSubmitRefusal.memberMismatch(
            index: 0))))
        let short = Harness.refusal { () throws(ActionSetSubmitRefusal) in
            try ActionSetFireRecord.make(set: resolved.set, stamps: stamps, handles: [record.handles[0]])
        }
        #expect(String(describing: short) == String(describing: Optional(ActionSetSubmitRefusal.memberCount(
            expected: 2, actual: 1))))
        #expect(try ActionSetFireRecord.make(set: resolved.set, stamps: stamps, handles: record.handles) == record)
    }
}

enum ActionSetSubmissionSchedulerCase: CaseIterable, Sendable {
    case staleSession, duplicateID, duplicateLast, outcomeCapacity, musicalFirst, musicalLast

    var index: Int {
        switch self {
        case .staleSession, .musicalFirst: 0
        case .duplicateID: 1
        case .duplicateLast, .outcomeCapacity, .musicalLast: 2
        }
    }

    func matches(_ error: any Error) -> Bool {
        switch self {
        case .staleSession: error as? TriggerSessionError == .staleSession
        case .duplicateID, .duplicateLast: error as? TriggerSessionError == .duplicateID
        case .outcomeCapacity: error as? TriggerSessionError == .outcomeCapacity
        case .musicalFirst, .musicalLast: error as? TriggerSchedulerError == .musicalContextRequired
        }
    }
}
