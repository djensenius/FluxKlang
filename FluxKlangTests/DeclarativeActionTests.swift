import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Test-local composition helpers for #107 action sets; pure values only.
struct ActionSetFixture {
    static let primary = ClockID(validated: "smp.sets")
    static let musical = ClockID(validated: "mus.sets")
    static let context = GenerationKey(.context, GenerationSubject(validated: "context.sets"))
    static let scene = GenerationSubject(validated: "scope.scene")
    static let other = GenerationSubject(validated: "scope.other")
    static let asset = AssetID(validated: "asset.sets")
    static let timebase = HostTimebase(numer: 125, denom: 3)
    /// Declared by every fixture, so member requirements never rely on an undeclared `.initial`.
    static let sourceKeys = (0..<6).map { index in
        GenerationKey(kind: .source, subject: GenerationSubject(rawValue: "source.\(index)") ?? scene)
    }

    var ledger: GenerationLedger
    var readiness = ActionReadiness()

    init(musical: Bool = true, scopes: [GenerationSubject] = [scene], counters: [GenerationKey] = []) throws {
        let scopeKeys = scopes.map { GenerationKey(kind: .cancelScope, subject: $0) }
        ledger = try GenerationLedger(primaryClock: Self.primary, musicalClock: musical ? Self.musical : nil,
                                      nominalRate: 48_000,
                                      declaring: [Self.context] + scopeKeys + Self.sourceKeys + counters)
    }

    static func ids(_ count: Int, prefix: String = "act") throws -> [ActionID] {
        try (0..<count).map { index throws -> ActionID in try ActionID("\(prefix).\(index)") }
    }

    static func statePolicy(_ late: LatePolicy = .drop, grid: Int64? = nil) throws -> ActionPolicy {
        try ActionPolicy(media: .state, timePolicy: nil, latePolicy: late, gridTicks: grid)
    }

    static func actions(_ ids: [ActionID]) throws -> [ProjectMediaAction] {
        try ids.map { ProjectMediaAction(id: $0, asset: asset, policy: try statePolicy()) }
    }

    static func resolved(_ ids: [ActionID], set: String = "set.a",
                         scope: GenerationSubject = scene) throws -> ResolvedActionSet {
        try resolved(actions(ids), set: set, scope: scope)
    }

    static func resolved(_ actions: [ProjectMediaAction], set: String = "set.a",
                         scope: GenerationSubject = scene) throws -> ResolvedActionSet {
        let model = try PerformanceActionSet(id: ActionSetID(set), members: actions.map(\.id), cancelScope: scope)
        return try PerformanceActionSetLibrary(sets: [model]).resolve(model.id, in: actions)
    }

    static func request(_ base: String = "trg.fire", target: TriggerTarget = .asap,
                        extra: [ActionID: [GenerationRequirement]] = [:]) throws -> ActionSetFireRequest {
        ActionSetFireRequest(baseTrigger: try TriggerID(base), originHost: HostStamp(ticks: 7), horizonFrame: 480,
                             target: target, context: context, memberRequirements: extra)
    }

    mutating func ready(_ ids: [ActionID], against requirements: [GenerationRequirement] = []) throws {
        for action in ids {
            try readiness.transition(action, to: .preparing)
            try readiness.markReady(action, preparedAgainst: requirements, ledger: ledger)
        }
    }

    func decide(_ resolved: ResolvedActionSet, _ request: ActionSetFireRequest) throws -> ActionSetFireDecision {
        try ActionSetTriggerBuilder.decide(resolved, request: request, readiness: readiness, ledger: ledger)
    }

    func sources(_ count: Int) throws -> [GenerationRequirement] {
        try Self.sourceKeys.prefix(count).map(current)
    }

    func current(_ key: GenerationKey) throws -> GenerationRequirement {
        let generation = try #require(ledger.generation(key))
        return GenerationRequirement(key: key, generation: generation)
    }
}

@Suite(.productionAccessAudit)
struct DeclarativeActionTests {
    static let setID = ActionSetID(validated: "set.a")

    @Test
    func membersBoundAtSixteenAndRefuseEmptyAndDuplicates() throws {
        let single = try PerformanceActionSet(id: Self.setID, members: ActionSetFixture.ids(1))
        #expect(single.cancelScope.rawValue == "set.a" && single.cancelScopeKey.kind == .cancelScope)
        #expect(try PerformanceActionSet(id: Self.setID, members: ActionSetFixture.ids(16)).members.count == 16)
        #expect(throws: ActionSetRefusal.tooManyMembers(17)) {
            try PerformanceActionSet(id: Self.setID, members: ActionSetFixture.ids(17))
        }
        #expect(throws: ActionSetRefusal.emptySet) { try PerformanceActionSet(id: Self.setID, members: []) }
        let ids = try ActionSetFixture.ids(2)
        #expect(throws: ActionSetRefusal.duplicateMember(ids[0])) {
            try PerformanceActionSet(id: Self.setID, members: [ids[0], ids[1], ids[0]])
        }
    }

    @Test
    func nameBoundIsUTF8Bytes() throws {
        let members = try ActionSetFixture.ids(1)
        for name in [String(repeating: "n", count: 128), String(repeating: "é", count: 64), "x"] {
            #expect(try PerformanceActionSet(id: Self.setID, name: name, members: members).name == name)
        }
        for (name, bytes) in [(String(repeating: "n", count: 129), 129), (String(repeating: "é", count: 65), 130),
                              ("", 0)] {
            #expect(throws: ActionSetRefusal.invalidName(bytes)) {
                try PerformanceActionSet(id: Self.setID, name: name, members: members)
            }
        }
    }

    @Test
    func resolvesMembersInDeclaredOrderAgainstProjectActions() throws {
        let ids = try ActionSetFixture.ids(3)
        let audio = try ProjectMediaAction(
            id: ids[1], asset: ActionSetFixture.asset,
            policy: ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .fireLate(maxLatenessMs: 40))
        )
        let project = try ActionSetFixture.actions([ids[0]]) + [audio] + ActionSetFixture.actions([ids[2]])
        let model = try PerformanceActionSet(id: Self.setID, members: [ids[2], ids[1], ids[0]])
        let library = try PerformanceActionSetLibrary(sets: [model])
        let resolved = try library.resolve(Self.setID, in: project)
        #expect(resolved.actions.map(\.id) == [ids[2], ids[1], ids[0]])
        #expect(resolved.mediaKinds == [.audio, .state])
        try library.validate(against: project)
        #expect(throws: ActionSetRefusal.unknownMember(ids[1])) {
            try library.resolve(Self.setID, in: ActionSetFixture.actions([ids[0], ids[2]]))
        }
        #expect(throws: ActionSetRefusal.unknownMember(ids[2])) {
            try library.validate(against: ActionSetFixture.actions([ids[0], ids[1]]))
        }
        #expect(throws: ActionSetRefusal.ambiguousProjectAction(ids[0])) {
            try library.resolve(Self.setID, in: project + ActionSetFixture.actions([ids[0]]))
        }
        let missing = ActionSetID(validated: "set.missing")
        #expect(throws: ActionSetRefusal.unknownSet(missing)) { try library.resolve(missing, in: project) }
    }

    @Test
    func libraryBoundAtTwoHundredFiftySixUniqueSets() throws {
        let members = try ActionSetFixture.ids(1)
        let sets = try (0..<257).map { index throws -> PerformanceActionSet in
            try PerformanceActionSet(id: ActionSetID("set.\(index)"), members: members)
        }
        #expect(try PerformanceActionSetLibrary(sets: Array(sets.prefix(256))).sets.count == 256)
        #expect(throws: ActionSetRefusal.tooManySets(257)) { try PerformanceActionSetLibrary(sets: sets) }
        #expect(throws: ActionSetRefusal.duplicateSet(sets[0].id)) {
            try PerformanceActionSetLibrary(sets: [sets[0], sets[1], sets[0]])
        }
    }

    @Test
    func codableRoundTripKeepsUnknownFieldsAndExtensions() throws {
        let json = """
        {"sets":[{"id":"set.a","name":"Intro","members":["act.1","act.0"],"cancelScope":"scope.scene",
        "futureSet":{"depth":1},"extensions":{"vendor.flag":true}}],"futureLibrary":[1,2]}
        """
        let library = try JSONDecoder().decode(PerformanceActionSetLibrary.self, from: Data(json.utf8))
        let model = try #require(library.sets.first)
        #expect(model.members.map(\.rawValue) == ["act.1", "act.0"] && model.cancelScope == ActionSetFixture.scene)
        #expect(model.unknownFields == ["futureSet": .object(["depth": .int(1)])])
        #expect(model.extensions == ["vendor.flag": .bool(true)])
        #expect(library.unknownFields == ["futureLibrary": .array([.int(1), .int(2)])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first = try encoder.encode(library)
        let again = try JSONDecoder().decode(PerformanceActionSetLibrary.self, from: first)
        #expect(again == library)
        #expect(try encoder.encode(again) == first)
        #expect(String(bytes: first, encoding: .utf8)?.contains("\"futureSet\"") == true)
        let invalid = [
            #"{"sets":[{"id":"set.a","members":[],"cancelScope":"scope.scene"}]}"#,
            #"{"sets":[{"id":"set.a","members":["act.0","act.0"],"cancelScope":"scope.scene"}]}"#,
            #"{"sets":[{"id":"set.a","members":["act.0"],"cancelScope":"scope.scene","name":""}]}"#,
            #"{"sets":[{"id":"set.a","members":["act.0"],"cancelScope":"s"},"#
                + #"{"id":"set.a","members":["act.1"],"cancelScope":"s"}]}"#
        ]
        for text in invalid {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(PerformanceActionSetLibrary.self, from: Data(text.utf8))
            }
        }
    }

    @Test
    func readinessTakesTheWorstStateAndKeepsEveryReason() throws {
        var fixture = try ActionSetFixture()
        let ids = try ActionSetFixture.ids(5)
        try fixture.ready([ids[0], ids[3]])
        try fixture.readiness.transition(ids[1], to: .preparing)
        try fixture.readiness.transition(ids[2], to: .preparing)
        let stretch = try ActionPolicy(media: .audio, timePolicy: .timeStretch, latePolicy: .drop)
        #expect(throws: ReadinessError.timeStretchUnavailable) {
            try fixture.readiness.markReady(ids[2], preparedAgainst: [], ledger: fixture.ledger, policy: stretch)
        }
        try fixture.readiness.transition(ids[3], to: .invalidated)
        let report = try ActionSetReadinessAggregate.evaluate(
            ActionSetFixture.resolved(ids), readiness: fixture.readiness, ledger: fixture.ledger
        )
        #expect(report.state == .failed && !report.isReady && report.members.count == 5)
        #expect(report.notReady == [
            ActionSetMemberStatus(action: ids[1], state: .preparing, reason: nil),
            ActionSetMemberStatus(action: ids[2], state: .failed, reason: .timeStretchUnavailable),
            ActionSetMemberStatus(action: ids[3], state: .invalidated, reason: .explicitInvalidation),
            ActionSetMemberStatus(action: ids[4], state: .unprepared, reason: nil)
        ])
        let pairs: [([ReadinessState], ReadinessState)] = [
            ([.invalidated, .failed], .failed), ([.unprepared, .invalidated], .invalidated),
            ([.preparing, .unprepared], .unprepared), ([.ready, .preparing], .preparing), ([.ready, .ready], .ready)
        ]
        for (states, expected) in pairs {
            #expect(ActionSetReadinessAggregate.combine(states) == expected)
            #expect(ActionSetReadinessAggregate.combine(states.reversed()) == expected)
        }
    }

    @Test
    func readyButStaleMemberIsNotReady() throws {
        let source = GenerationKey(.source, StreamID(validated: "source.sets"))
        var fixture = try ActionSetFixture(counters: [source])
        let ids = try ActionSetFixture.ids(2)
        try fixture.ready([ids[0]], against: [fixture.current(source)])
        try fixture.ready([ids[1]])
        let resolved = try ActionSetFixture.resolved(ids)
        let fresh = ActionSetReadinessAggregate.evaluate(resolved, readiness: fixture.readiness, ledger: fixture.ledger)
        #expect(fresh.isReady && fresh.notReady.isEmpty)
        try fixture.ledger.bump(source, reason: .sourceLost)
        #expect(fixture.readiness.state(ids[0]) == .ready)
        let stale = ActionSetReadinessAggregate.evaluate(resolved, readiness: fixture.readiness, ledger: fixture.ledger)
        #expect(stale.state == .invalidated)
        #expect(stale.notReady == [ActionSetMemberStatus(action: ids[0], state: .invalidated, reason: .sourceChanged)])
        guard case .dropped = try fixture.decide(resolved, ActionSetFixture.request()) else {
            Issue.record("A stale member must drop the set")
            return
        }
    }
}
