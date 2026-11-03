import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct PreparationProjectBudgetTests {
    static func empty() -> ProjectDocument {
        ProjectDocument(id: ProjectID(validated: "prj.p"), name: "")
    }

    static func nested(_ wrappers: Int) -> JSONValue {
        (0..<wrappers).reduce(JSONValue.null) { value, _ in .array([value]) }
    }

    static func privatePolicy(_ value: JSONValue) throws -> ActionPolicy {
        let json = JSONValue.object([
            "media": .string("audio"), "timePolicy": .string("fixedRate"),
            "latePolicy": .object(["drop": .object([:]), "future": value]),
            "retroactiveMs": .int(0), "stoppedPolicy": .string("wait")
        ])
        return try ContractCoding.decode(ActionPolicy.self, from: ContractCoding.makeEncoder().encode(json))
    }

    static func withPolicy(_ policy: ActionPolicy) -> ProjectDocument {
        var project = empty()
        project.actions = [ProjectMediaAction(
            id: ActionID(validated: "act.a"), asset: AssetID(validated: "ast.a"), policy: policy
        )]
        return project
    }

    @Test func retainedRootTextBoundaryIncludesHeaderAndElidedCollision() throws {
        var project = Self.empty()
        // Header 32; stored field names 68; ID 5; colliding unknown key 4.
        // The extra "name" is charged even though encoding drops its value.
        project.unknownFields = ["name": .string(String(repeating: "x", count: 131_072 - 109))]
        try PreparationProjectBudget.check(project)
        #expect(try project.encoded() == Self.empty().encoded())
        project.unknownFields["name"] = .string(String(repeating: "x", count: 131_072 - 108))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }

    @Test(arguments: ["contract", "version", "requiredFeatures", "extensions", "unknownFields"])
    func collidingKeysAreStillRetained(key: String) {
        var project = Self.empty()
        project.unknownFields[key] = .string(String(repeating: "x", count: 131_072))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }

    @Test func utf8NotCharacterCountAndOversizedKeys() throws {
        var project = Self.empty()
        // 105 base bytes + one key byte, leaving an even number of UTF-8 bytes.
        project.unknownFields = ["x": .string(String(repeating: "é", count: (131_072 - 106) / 2))]
        try PreparationProjectBudget.check(project)
        project.unknownFields["x"] = .string(String(repeating: "é", count: (131_072 - 106) / 2) + "a")
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        project.unknownFields = [String(repeating: "🔊", count: 32_768): .null]
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }

    @Test func exactRetainedDepthBoundary() throws {
        var project = Self.empty()
        // root 1 / unknown dictionary 2 / value 3, then 29 arrays -> scalar 32.
        project.unknownFields = ["x": Self.nested(29)]
        try PreparationProjectBudget.check(project)
        project.unknownFields["x"] = Self.nested(30)
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }

    @Test func privatePolicyDepthAndOversizedMetadataAreNotHiddenByCoding() throws {
        // root 1 / actions 2 / action 3 / policy 4 / private bag 5 / value 6.
        let admitted = Self.withPolicy(try Self.privatePolicy(Self.nested(26)))
        try PreparationProjectBudget.check(admitted)
        let deep = Self.withPolicy(try Self.privatePolicy(Self.nested(27)))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(deep) }
        let large = Self.withPolicy(try Self.privatePolicy(.string(String(repeating: "x", count: 131_072))))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(large) }
    }

    @Test func numericAndWideCollectionsReachValueBoundary() throws {
        var project = Self.empty()
        // Empty project: 13 values, 12 members. One array adds a value/member.
        project.unknownFields = ["n": .array(Array(repeating: .int(0), count: 16_370))]
        try PreparationProjectBudget.check(project)
        project.unknownFields["n"] = .array(Array(repeating: .uint(.max), count: 16_371))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        project.unknownFields = Dictionary(uniqueKeysWithValues: (0..<16_371).map { ("k\($0)", JSONValue.null) })
        try PreparationProjectBudget.check(project)
        project.unknownFields["extra"] = .bool(true)
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        // Values = members + 1: the equal member cap cannot bind independently.
    }

    @Test(arguments: [JSONValue.array([]), .object([:])])
    func emptyContainersReachInclusiveBoundary(emptyContainer: JSONValue) throws {
        var project = Self.empty()
        // Seven baseline containers, one outer array, 2040 empty children.
        project.unknownFields = ["n": .array(Array(repeating: emptyContainer, count: 2_040))]
        try PreparationProjectBudget.check(project)
        project.unknownFields["n"] = .array(Array(repeating: emptyContainer, count: 2_041))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }

    @Test func aggregateBudgetsCountSharedOccurrencesAcrossBags() throws {
        var project = Self.empty()
        let text = JSONValue.string(String(repeating: "x", count: 66_000))
        project.extensions = ["x": text]
        try PreparationProjectBudget.check(project)
        project.unknownFields = ["x": text]
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        let numbers = JSONValue.array(Array(repeating: .double(0.5), count: 8_200))
        project.extensions = ["x": numbers]
        project.unknownFields = [:]
        try PreparationProjectBudget.check(project)
        project.unknownFields = ["x": numbers]
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        let containers = JSONValue.array(Array(repeating: .object([:]), count: 1_024))
        project.extensions = ["x": containers]
        project.unknownFields = [:]
        try PreparationProjectBudget.check(project)
        project.unknownFields = ["x": containers]
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }

    @Test(arguments: [
        LatePolicy.drop, .fireLate(maxLatenessMs: 20), .joinInProgress(maxLatenessMs: 20),
        .nextBoundary(gridTicks: nil), .nextBoundary(gridTicks: 10)
    ])
    func policyRecordIsChargedOnceIncludingOptionalPayload(policy: LatePolicy) throws {
        let policy = try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: policy, gridTicks: 10)
        var project = Self.withPolicy(policy)
        let tag: String
        switch policy.latePolicy {
        case .drop: tag = "drop"
        case .fireLate: tag = "fireLate"
        case .joinInProgress: tag = "joinInProgress"
        case .nextBoundary: tag = "nextBoundary"
        }
        let actionText = "idassetpolicyextensionsunknownFieldsact.aast.a"
        let policyText = "mediatimePolicylatePolicygridTicksretroactiveMsstoppedPolicy"
            + "unknownFieldsextensionslatePolicyUnknownFieldstagpayloadaudiofixedRatewait" + tag
        let available = 131_072 - 105 - actionText.utf8.count - policyText.utf8.count - 1
        project.unknownFields["x"] = .string(String(repeating: "a", count: available))
        try PreparationProjectBudget.check(project)
        project.unknownFields["x"] = .string(String(repeating: "a", count: available + 1))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        // Base 13 + action 6 + policy's 9 fields + late policy's 2 fields = 30.
        // The policy itself replaces the action field value, not an extra node.
        project.unknownFields = ["n": .array(Array(repeating: .null, count: 16_353))]
        try PreparationProjectBudget.check(project)
        project.unknownFields["n"] = .array(Array(repeating: .null, count: 16_354))
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }

    @Test func everyRecordBagAndTypedTextContributes() throws {
        var (base, _) = ProjectContractTests.sample()
        base.actions = Self.withPolicy(try Self.privatePolicy(.null)).actions
        let oversized: [String: JSONValue] = ["x": .string(String(repeating: "x", count: 131_072))]
        let bags: [WritableKeyPath<ProjectDocument, [String: JSONValue]>] = [
            \.unknownFields, \.roles[0].unknownFields, \.graphs[0].unknownFields,
            \.patches[0].unknownFields, \.assets[0].unknownFields, \.actions[0].unknownFields,
            \.actions[0].policy.unknownFields
        ]
        for path in bags {
            var project = base
            project[keyPath: path] = oversized
            #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        }
        let extensions: [WritableKeyPath<ProjectDocument, [String: JSONValue]?>] = [
            \.extensions, \.roles[0].extensions, \.graphs[0].extensions, \.patches[0].extensions,
            \.assets[0].extensions, \.actions[0].extensions, \.actions[0].policy.extensions
        ]
        for path in extensions {
            var project = base
            project[keyPath: path] = oversized
            #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        }
        let labels: [WritableKeyPath<ProjectDocument, String>] = [
            \.name, \.roles[0].label, \.patches[0].label, \.assets[0].label, \.assets[0].contentDigest
        ]
        for path in labels {
            var project = base
            project[keyPath: path] = String(repeating: "x", count: 131_072)
            #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        }
        var project = base
        project.assets[0].timing?.unknownFields = oversized
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
        project = base
        project.assets[0].timing?.extensions = oversized
        #expect(throws: PreparationProjectRefusal.structuralLimit) { try PreparationProjectBudget.check(project) }
    }
}
