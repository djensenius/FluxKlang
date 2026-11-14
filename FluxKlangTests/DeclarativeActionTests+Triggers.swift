import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct DeclarativeActionTriggerTests {
    static let sceneKey = GenerationKey(kind: .cancelScope, subject: ActionSetFixture.scene)
    static let otherKey = GenerationKey(kind: .cancelScope, subject: ActionSetFixture.other)
    static let transport = GenerationKey(.transport, ActionSetFixture.musical)

    static func stamps(_ decision: ActionSetFireDecision) throws -> [TriggerStamp] {
        guard case .fire(let stamps) = decision else {
            Issue.record("Expected a fire decision, got \(decision)")
            throw ActionSetRefusal.emptySet
        }
        return stamps
    }

    @Test
    func notReadySetDropsWholeSetAndReportsEveryMember() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(3)
        try fixture.ready([ids[0], ids[1]])
        let decision = try fixture.decide(ActionSetFixture.resolved(ids), ActionSetFixture.request())
        guard case .dropped(let report) = decision else {
            Issue.record("A not-ready set must not fire any member")
            return
        }
        #expect(report.set == ActionSetID(validated: "set.a") && report.reason == .notReady)
        #expect(report.readiness.state == .unprepared && report.readiness.members.count == 3)
        #expect(report.readiness.notReady == [ActionSetMemberStatus(action: ids[2], state: .unprepared, reason: nil)])
    }

    @Test
    func readySetBuildsOneValidStampPerMemberInDeclaredOrder() throws {
        var fixture = try ActionSetFixture()
        try fixture.ledger.bump(Self.sceneKey, reason: .userCancel)
        let ids = try ActionSetFixture.ids(3)
        let project = try [
            ProjectMediaAction(id: ids[2], asset: ActionSetFixture.asset, policy: ActionSetFixture.statePolicy()),
            ProjectMediaAction(id: ids[0], asset: ActionSetFixture.asset, policy: ActionPolicy(
                media: .audio, timePolicy: .fixedRate, latePolicy: .fireLate(maxLatenessMs: 50), retroactiveMs: 20)),
            ProjectMediaAction(id: ids[1], asset: ActionSetFixture.asset, policy: ActionPolicy(
                media: .midi, timePolicy: .fixedRate, latePolicy: .joinInProgress(maxLatenessMs: 30),
                stoppedPolicy: .immediate))
        ]
        try fixture.ready(ids)
        let stamps = try Self.stamps(fixture.decide(ActionSetFixture.resolved(project), ActionSetFixture.request()))
        #expect(stamps.map(\.id.rawValue) == ["trg.fire.0", "trg.fire.1", "trg.fire.2"])
        #expect(stamps.map(\.action) == [ids[2], ids[0], ids[1]])
        let expected = try [fixture.current(fixture.ledger.primaryClock), fixture.current(ActionSetFixture.context),
                            fixture.current(Self.sceneKey)]
        #expect(expected[2].generation.value == 2)
        for stamp in stamps {
            #expect(stamp.requires == expected)
            #expect(stamp.originHost == HostStamp(ticks: 7) && stamp.horizonFrame == 480 && stamp.target == .asap)
            try stamp.validate(primaryClock: fixture.ledger.primaryClock, musicalClock: ActionSetFixture.musical)
        }
        #expect(stamps.map(\.latePolicy) == [.drop, .fireLate(maxLatenessMs: 50), .joinInProgress(maxLatenessMs: 30)])
        #expect(stamps.map(\.retroactiveMs) == [0, 20, 0])
        #expect(stamps.map(\.stoppedPolicy) == [.wait, .wait, .immediate])
    }

    @Test
    func musicalTargetsAndNextBoundaryRequireTransportNeverMusicalMap() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(2)
        let project = try [
            ProjectMediaAction(id: ids[0], asset: ActionSetFixture.asset, policy: ActionSetFixture.statePolicy()),
            ProjectMediaAction(id: ids[1], asset: ActionSetFixture.asset,
                               policy: ActionSetFixture.statePolicy(.nextBoundary(gridTicks: nil), grid: 960))
        ]
        try fixture.ready(ids)
        let resolved = try ActionSetFixture.resolved(project)
        let asap = try Self.stamps(fixture.decide(resolved, ActionSetFixture.request()))
        #expect(!asap[0].requires.map(\.key).contains(Self.transport))
        #expect(try asap[1].requires.last == fixture.current(Self.transport))
        #expect(asap[1].latePolicy == .nextBoundary(gridTicks: 960) && asap[1].fallbackGrid == 960)
        let grid = try Self.stamps(fixture.decide(resolved, ActionSetFixture.request(target: .grid(ticks: 3_840))))
        for stamp in asap + grid {
            #expect(!stamp.requires.contains { $0.key.kind == .musicalMap })
        }
        let transport = try fixture.current(Self.transport)
        #expect(grid.map(\.requires.count) == [4, 4] && grid.map { $0.requires[3] } == [transport, transport])
    }

    @Test
    func requirementBudgetPinsAtEight() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(1)
        try fixture.ready(ids)
        let resolved = try ActionSetFixture.resolved(ids)
        let five = try fixture.sources(5)
        let flat = try Self.stamps(fixture.decide(resolved, ActionSetFixture.request(extra: [ids[0]: five])))
        #expect(flat[0].requires.count == 8 && Array(flat[0].requires.suffix(5)) == five)
        #expect(throws: ActionSetRefusal.tooManyRequirements(ids[0], 9)) {
            try fixture.decide(resolved, ActionSetFixture.request(extra: [ids[0]: fixture.sources(6)]))
        }
        let musical = try Self.stamps(fixture.decide(resolved, ActionSetFixture.request(
            target: .musical(atTicks: 0), extra: [ids[0]: fixture.sources(4)])))
        #expect(musical[0].requires.count == 8)
        #expect(throws: ActionSetRefusal.tooManyRequirements(ids[0], 9)) {
            try fixture.decide(resolved, ActionSetFixture.request(target: .musical(atTicks: 0),
                                                                  extra: [ids[0]: fixture.sources(5)]))
        }
        for key in [ActionSetFixture.context, Self.otherKey, Self.transport] {
            let owned = GenerationRequirement(key: key, generation: .initial)
            #expect(throws: ActionSetRefusal.invalidMemberRequirement(ids[0], key)) {
                try fixture.decide(resolved, ActionSetFixture.request(extra: [ids[0]: [owned]]))
            }
        }
    }

    @Test
    func triggerIDLengthPinsAtOneHundredTwentyEight() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(11)
        try fixture.ready(ids)
        let base = String(repeating: "t", count: 126)
        let ten = try Self.stamps(fixture.decide(ActionSetFixture.resolved(Array(ids.prefix(10))),
                                                 ActionSetFixture.request(base)))
        #expect(ten.last?.id.rawValue == base + ".9" && ten.last?.id.rawValue.utf8.count == 128)
        #expect(throws: ActionSetRefusal.triggerIDTooLong(129)) {
            try fixture.decide(ActionSetFixture.resolved(ids), ActionSetFixture.request(base))
        }
        #expect(throws: ActionSetRefusal.triggerIDTooLong(129)) {
            try fixture.decide(ActionSetFixture.resolved([ids[0]]), ActionSetFixture.request(base + "t"))
        }
    }

    @Test
    func contextCounterAndContractRefusals() throws {
        var fixture = try ActionSetFixture(musical: false)
        let ids = try ActionSetFixture.ids(1)
        try fixture.ready(ids)
        let resolved = try ActionSetFixture.resolved(ids)
        let wrongContext = GenerationKey(.source, StreamID(validated: "source.sets"))
        let request = try ActionSetFixture.request()
        #expect(throws: ActionSetRefusal.invalidContext(wrongContext)) {
            try ActionSetTriggerBuilder.decide(resolved, request: ActionSetFireRequest(
                baseTrigger: request.baseTrigger, originHost: request.originHost, horizonFrame: 0, target: .asap,
                context: wrongContext), readiness: fixture.readiness, ledger: fixture.ledger)
        }
        #expect(throws: ActionSetRefusal.undeclaredCounter(Self.otherKey)) {
            try fixture.decide(ActionSetFixture.resolved(ids, scope: ActionSetFixture.other), request)
        }
        #expect(throws: ActionSetRefusal.invalidTrigger(ids[0], .missingTransport)) {
            try fixture.decide(resolved, ActionSetFixture.request(target: .grid(ticks: 960)))
        }
        let unready = try ActionSetFixture(musical: false)
        #expect(throws: ActionSetRefusal.invalidTrigger(ids[0], .missingTransport)) {
            try unready.decide(resolved, ActionSetFixture.request(target: .grid(ticks: 960)))
        }
    }

    @Test
    func decisionIsDeterministic() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(3)
        try fixture.ready(ids)
        let resolved = try ActionSetFixture.resolved([ids[2], ids[0], ids[1]])
        let request = try ActionSetFixture.request(extra: [ids[1]: fixture.sources(2), ids[0]: fixture.sources(1)])
        let first = try fixture.decide(resolved, request)
        #expect(try fixture.decide(resolved, request) == first)
        #expect(try Self.stamps(first).map(\.action) == [ids[2], ids[0], ids[1]])
    }

    @Test
    func userCancelCancelsExactlyItsScopeOnce() throws {
        var fixture = try ActionSetFixture(scopes: [ActionSetFixture.scene, ActionSetFixture.other])
        let ids = try ActionSetFixture.ids(3)
        try fixture.ready(ids)
        var pending = ActionSetPendingTriggers()
        let scopes = [ActionSetFixture.scene, ActionSetFixture.other, ActionSetFixture.scene]
        for (index, scope) in scopes.enumerated() {
            let resolved = try ActionSetFixture.resolved([ids[index]], set: "set.\(index)", scope: scope)
            try pending.register(Self.stamps(fixture.decide(resolved, ActionSetFixture.request("trg.\(index)"))),
                                 ledger: fixture.ledger)
        }
        #expect(pending.pending(in: ActionSetFixture.scene).map(\.rawValue) == ["trg.0.0", "trg.2.0"])
        let cancelled = try pending.userCancel(scope: ActionSetFixture.scene, ledger: &fixture.ledger)
        #expect(cancelled.map(\.rawValue) == ["trg.0.0", "trg.2.0"])
        #expect(pending.count == 1 && pending.pending(in: ActionSetFixture.other).map(\.rawValue) == ["trg.1.0"])
        #expect(fixture.ledger.generation(Self.sceneKey)?.value == 2)
        #expect(fixture.ledger.generation(Self.otherKey)?.value == 1)
        #expect(try pending.userCancel(scope: ActionSetFixture.scene, ledger: &fixture.ledger).isEmpty)
        #expect(pending.count == 1 && fixture.ledger.generation(Self.sceneKey)?.value == 3)
        #expect(fixture.ledger.generation(Self.otherKey)?.value == 1)
    }

    @Test
    func oldEpochNeverBecomesFresh() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(2)
        try fixture.ready(ids)
        let resolved = try ActionSetFixture.resolved(ids)
        let old = try Self.stamps(fixture.decide(resolved, ActionSetFixture.request()))
        var pending = ActionSetPendingTriggers()
        try pending.register(old, ledger: fixture.ledger)
        #expect(try pending.userCancel(scope: ActionSetFixture.scene, ledger: &fixture.ledger).count == 2)
        #expect(throws: ActionSetRefusal.staleScope(old[0].id)) { try pending.register(old, ledger: fixture.ledger) }
        #expect(pending.count == 0)
        #expect(old.allSatisfy { !$0.requires.allSatisfy(fixture.ledger.isCurrent) })
        let fresh = try Self.stamps(fixture.decide(resolved, ActionSetFixture.request("trg.again")))
        let scope = try fixture.current(Self.sceneKey)
        #expect(scope.generation.value == 2 && fresh.map { $0.requires[2] } == [scope, scope])
        try pending.register(fresh, ledger: fixture.ledger)
        #expect(pending.count == 2)
    }

    @Test
    func pendingRegistryBoundsAndRefusals() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(16)
        try fixture.ready(ids)
        let resolved = try ActionSetFixture.resolved(ids)
        var pending = ActionSetPendingTriggers()
        for fire in 0..<16 {
            try pending.register(Self.stamps(fixture.decide(resolved, ActionSetFixture.request("trg.\(fire)"))),
                                 ledger: fixture.ledger)
        }
        #expect(pending.count == 256)
        let extra = try Self.stamps(fixture.decide(resolved, ActionSetFixture.request("trg.extra")))
        #expect(throws: ActionSetRefusal.pendingCapacity) { try pending.register(extra[0], ledger: fixture.ledger) }
        #expect(pending.complete(TriggerID(validated: "trg.0.0")) && !pending.complete(TriggerID(validated: "trg.0.0")))
        #expect(throws: ActionSetRefusal.duplicatePending(extra[0].id)) {
            try pending.register([extra[0], extra[0]], ledger: fixture.ledger)
        }
        #expect(pending.count == 255)
        try pending.register(extra[0], ledger: fixture.ledger)
        #expect(pending.count == 256)
        let bare = TriggerStamp(id: TriggerID(validated: "trg.bare"), action: ids[0], originHost: HostStamp(ticks: 0),
                                horizonFrame: 0, requires: [], target: .asap, latePolicy: .drop)
        #expect(throws: ActionSetRefusal.notSetTrigger(bare.id)) { try pending.register(bare, ledger: fixture.ledger) }
        let scope = try fixture.current(Self.sceneKey)
        let twice = TriggerStamp(id: TriggerID(validated: "trg.twice"), action: ids[0], originHost: HostStamp(ticks: 0),
                                 horizonFrame: 0, requires: [scope, scope], target: .asap, latePolicy: .drop)
        #expect(throws: ActionSetRefusal.notSetTrigger(twice.id)) {
            try pending.register(twice, ledger: fixture.ledger)
        }
        let ledgerBefore = fixture.ledger.current
        #expect(throws: ActionSetRefusal.cancelFailed(.undeclaredCounter(Self.otherKey))) {
            try pending.userCancel(scope: ActionSetFixture.other, ledger: &fixture.ledger)
        }
        #expect(pending.count == 256 && fixture.ledger.current == ledgerBefore)
    }

    @Test
    func staleMemberRequirementDropsTheWholeSet() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(2)
        try fixture.ready(ids)
        let source = ActionSetFixture.sourceKeys[0]
        let request = try ActionSetFixture.request(extra: [ids[0]: fixture.sources(1), ids[1]: fixture.sources(2)])
        try fixture.ledger.bump(ActionSetFixture.sourceKeys[1], reason: .sourceLost)
        let decision = try fixture.decide(ActionSetFixture.resolved(ids), request)
        guard case .dropped(let report) = decision else {
            Issue.record("One stale member requirement must drop every member, got \(decision)")
            return
        }
        #expect(report.reason == .notReady && report.readiness.state == .invalidated)
        #expect(report.readiness.members[0] == ActionSetMemberStatus(action: ids[0], state: .ready, reason: nil))
        #expect(report.readiness.notReady == [ActionSetMemberStatus(
            action: ids[1], state: .invalidated, reason: .sourceChanged,
            staleRequirements: [ActionSetFixture.sourceKeys[1]]
        )])
        try fixture.ledger.bump(source, reason: .sourceLost)
        try fixture.readiness.transition(ids[0], to: .unprepared)
        guard case .dropped(let both) = try fixture.decide(ActionSetFixture.resolved(ids), request) else {
            Issue.record("Stale members must drop the set")
            return
        }
        let staleKeys = both.readiness.notReady.map(\.staleRequirements)
        #expect(staleKeys == [[source], [source, ActionSetFixture.sourceKeys[1]]])
        #expect(both.readiness.notReady.map(\.state) == [.unprepared, .invalidated])
    }

    @Test
    func undeclaredMemberRequirementIsACallerErrorBeforeAnyDrop() throws {
        let fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(2)
        let undeclared = GenerationKey(.source, StreamID(validated: "source.undeclared"))
        let request = try ActionSetFixture.request(
            extra: [ids[1]: [GenerationRequirement(key: undeclared, generation: .initial)]]
        )
        #expect(throws: ActionSetRefusal.undeclaredCounter(undeclared)) {
            try fixture.decide(ActionSetFixture.resolved(ids), request)
        }
    }

    @Test
    func everyEmittedTriggerIsAdmittedBySchedulerOrNoneIsEmitted() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(3)
        try fixture.ready(ids)
        let resolved = try ActionSetFixture.resolved(ids)
        var fired: [Int] = []
        for (round, bump) in [nil, ActionSetFixture.sourceKeys[2], nil].enumerated() {
            let request = try ActionSetFixture.request(
                "trg.round\(round)", extra: [ids[0]: fixture.sources(1), ids[2]: fixture.sources(3)]
            )
            if let bump { try fixture.ledger.bump(bump, reason: .sourceLost) }
            var scheduler = try TriggerScheduler(ledger: fixture.ledger, timebase: ActionSetFixture.timebase,
                                                 outcomeCapacity: 8)
            guard case .fire(let stamps) = try fixture.decide(resolved, request) else {
                fired.append(0)
                continue
            }
            for stamp in stamps {
                _ = try scheduler.submit(stamp, session: scheduler.currentToken, ledger: fixture.ledger,
                                         readiness: fixture.readiness)
            }
            #expect(scheduler.pendingCount == stamps.count && scheduler.reservedOutcomeCount == stamps.count)
            #expect(scheduler.drain().isEmpty)
            fired.append(stamps.count)
        }
        #expect(fired == [3, 0, 3])
    }

    /// `ResolvedActionSet` has only the library resolver as an initializer, so `decide` sees members only.
    @Test
    func foreignOrUnpreparedActionNeverReachesDecide() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(5)
        let project = try ActionSetFixture.actions(Array(ids.prefix(4)))
        try fixture.ready(Array(ids.prefix(3)))
        let scene = ActionSetFixture.scene
        let library = try PerformanceActionSetLibrary(sets: [
            PerformanceActionSet(id: ActionSetID("set.members"), members: [ids[1], ids[0]], cancelScope: scene),
            PerformanceActionSet(id: ActionSetID("set.unprepared"), members: [ids[0], ids[3]], cancelScope: scene),
            PerformanceActionSet(id: ActionSetID("set.foreign"), members: [ids[0], ids[4]], cancelScope: scene)
        ])
        let members = try library.resolve(ActionSetID("set.members"), in: project)
        #expect(members.actions.map(\.id) == [ids[1], ids[0]])
        let fired = try Self.stamps(fixture.decide(members, ActionSetFixture.request()))
        #expect(fired.map(\.action) == [ids[1], ids[0]])
        let unprepared = try library.resolve(ActionSetID("set.unprepared"), in: project)
        guard case .dropped(let report) = try fixture.decide(unprepared, ActionSetFixture.request()) else {
            Issue.record("An unprepared member must drop the set")
            return
        }
        #expect(report.readiness.notReady == [ActionSetMemberStatus(action: ids[3], state: .unprepared, reason: nil)])
        #expect(throws: ActionSetRefusal.unknownMember(ids[4])) {
            try library.resolve(ActionSetID("set.foreign"), in: project)
        }
    }
}
