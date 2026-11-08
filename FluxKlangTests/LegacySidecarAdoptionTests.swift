import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of the legacy sidecar plan: absence, exact retention, content probes and the production sources.
/// The Bounds, Order and Compose files extend this suite and share its fixtures.
struct LegacySidecarAdoptionTests {
    enum Fixture {
        static let projectID = ProjectID(validated: "prj.sidecars")
        static let graphID = GraphID(validated: "gph.sidecars")
        static let synth = "11111111-1111-1111-1111-111111111111"
        static let instrument = "22222222-2222-2222-2222-222222222222"
        static let mains = "33333333-3333-3333-3333-333333333333"
        static let mainsEndpoint = "BBBBBBBB-0000-0000-0000-000000000001"

        /// Odd spacing, key order, an escape, a number spelling and a trailing newline must survive byte for byte.
        static let draftBytes = Data("{ \"z\" : \"caf\\u00e9\",  \"a\":1.50e0 ,\"m\":[ 1 , 2 ]}\n".utf8)
        static let connectionsBytes = Data("{\"hosts\" :[ {\"name\":\"Wing\", \"port\":2223} ],\"a\":null}\n".utf8)
        static let standardEndpoints = Data((
            #"[{"id":"\#(mainsEndpoint)","name":"Mains","destination":"mains","colorName":"red"}]"#
        ).utf8)

        static func limits(entryBytes: Int = 65_536, totalBytes: Int = 262_144, entries: Int = 32) throws
            -> ProjectPackageLimits {
            try ProjectPackageLimits(
                maxEntries: entries, maxDepth: 8, maxPathUTF8Bytes: 256,
                maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            )
        }

        static func policy(entries: Int = 32, entryBytes: Int = 65_536, totalBytes: Int = 262_144) throws
            -> ProjectPackageManifestPolicy {
            try ProjectPackageManifestPolicy(
                packageLimits: limits(entryBytes: entryBytes, totalBytes: totalBytes, entries: entries),
                maxManifestBytes: min(4096, entryBytes)
            )
        }

        /// A JSON object of exactly `count` bytes (at least 8) holding one ASCII string.
        static func object(bytes count: Int) -> Data {
            let filler = String(repeating: "x", count: count - 8)
            return Data("{\"k\":\"\(filler)\"}".utf8)
        }

        /// Bytes that are not valid UTF-8 inside an otherwise well-formed object.
        static func invalidUTF8(_ bytes: [UInt8]) -> Data {
            let prefix: [UInt8] = Array("{\"k\":\"".utf8)
            let suffix: [UInt8] = Array("\"}".utf8)
            return Data(prefix + bytes + suffix)
        }

        static let lone: [UInt8] = [0xC3]
        static let overlong: [UInt8] = [0xC0, 0xAF]
        static let surrogate: [UInt8] = [0xED, 0xA0, 0x80]

        static func text(_ text: String) -> Data { Data(text.utf8) }

        static func refusal(
            draft: Data?, connections: Data?, limits: ProjectPackageLimits
        ) -> LegacySidecarRefusal? {
            do {
                _ = try LegacySidecarPlan.make(draft: draft, connections: connections, limits: limits)
                return nil
            } catch {
                return error
            }
        }

        /// The refusal for `data` supplied as one source with the other absent.
        static func refusal(source: LegacySidecarSource, data: Data, limits: ProjectPackageLimits)
            -> LegacySidecarRefusal? {
            switch source {
            case .pendingDraft: return refusal(draft: data, connections: nil, limits: limits)
            case .connections: return refusal(draft: nil, connections: data, limits: limits)
            }
        }

        static let graph = Data([
            #"{"nodes":[{"id":"\#(synth)","kind":{"instrument":{"_0":"\#(instrument)"}},"title":"Synth","#,
            #""position":[1.5,-2]},{"id":"\#(mains)","kind":{"endpoint":{"_0":"\#(mainsEndpoint)"}},"#,
            #""title":"Mains","position":[3,4]}],"edges":[{"id":"66666666-6666-6666-6666-666666666661","#,
            #""from":{"nodeID":"\#(synth)","side":"output","port":0},"#,
            #""to":{"nodeID":"\#(mains)","side":"input","port":0}}]}"#
        ].joined().utf8)

        static func adopted(endpoints: Data?) throws -> LegacyAdoptionResult {
            try LegacyAdoption.adopt(
                graphData: graph, endpointsData: endpoints, projectID: projectID, graphID: graphID,
                name: "Adopted", policy: policy()
            )
        }

        /// The refusal of composing `plan` onto `result` under `policy`, or `nil` when it composes.
        static func composeRefusal(
            _ plan: LegacySidecarPlan, _ result: LegacyAdoptionResult, _ policy: ProjectPackageManifestPolicy
        ) -> LegacySidecarRefusal? {
            do {
                _ = try plan.extending(result, policy: policy)
                return nil
            } catch {
                return error
            }
        }

        static func file(_ path: String, in contents: ProjectPackageContents) -> ProjectPackageFile? {
            let wanted = Array(path.utf8)
            return contents.files.first { Array($0.path.utf8) == wanted }
        }
    }

    // MARK: Absence and retention

    @Test
    func bothSidecarsAbsentGiveAnEmptyPlanWithNoFiles() throws {
        let plan = try LegacySidecarPlan.make(draft: nil, connections: nil, limits: Fixture.limits())
        #expect(plan.isEmpty)
        #expect(plan.files.isEmpty)
    }

    @Test
    func aDraftAloneGivesOneOpaqueStateFileAtTheDraftPathWithItsExactBytes() throws {
        let plan = try LegacySidecarPlan.make(draft: Fixture.draftBytes, connections: nil, limits: Fixture.limits())
        try #require(plan.files.count == 1)
        let file = plan.files[0]
        #expect(Array(file.path.utf8) == Array("legacy/PendingStudioDraft.json".utf8))
        #expect(file.role == .opaqueState)
        #expect(Array(file.bytes) == Array(Fixture.draftBytes))
        #expect(!plan.isEmpty)
    }

    @Test
    func aConnectionsFileAloneGivesOneOpaqueStateFileAtTheConnectionsPathWithItsExactBytes() throws {
        let plan = try LegacySidecarPlan.make(
            draft: nil, connections: Fixture.connectionsBytes, limits: Fixture.limits()
        )
        try #require(plan.files.count == 1)
        let file = plan.files[0]
        #expect(Array(file.path.utf8) == Array("legacy/StudioConnections.json".utf8))
        #expect(file.role == .opaqueState)
        #expect(Array(file.bytes) == Array(Fixture.connectionsBytes))
    }

    @Test
    func bothSidecarsGiveTheDraftFileFirstThenTheConnectionsFileWithTheirExactBytes() throws {
        let plan = try LegacySidecarPlan.make(
            draft: Fixture.draftBytes, connections: Fixture.connectionsBytes, limits: Fixture.limits()
        )
        try #require(plan.files.count == 2)
        #expect(Array(plan.files[0].path.utf8) == Array(LegacySidecarPlan.draftPath.utf8))
        #expect(Array(plan.files[1].path.utf8) == Array(LegacySidecarPlan.connectionsPath.utf8))
        #expect(Array(plan.files[0].bytes) == Array(Fixture.draftBytes))
        #expect(Array(plan.files[1].bytes) == Array(Fixture.connectionsBytes))
        let roles = plan.files.map(\.role)
        let expectedRoles: [ProjectPackageMemberRole] = [.opaqueState, .opaqueState]
        #expect(roles == expectedRoles)
    }

    @Test
    func retainedBytesAreTheCallersBytesAndACanonicalReEncodingOfThemWouldDiffer() throws {
        let decoded = try ContractCoding.decode(JSONValue.self, from: Fixture.draftBytes)
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(Array(reencoded) != Array(Fixture.draftBytes))
        let plan = try LegacySidecarPlan.make(draft: Fixture.draftBytes, connections: nil, limits: Fixture.limits())
        try #require(plan.files.count == 1)
        #expect(Array(plan.files[0].bytes) == Array(Fixture.draftBytes))
        #expect(Array(plan.files[0].bytes) != Array(reencoded))
    }

    @Test
    func aZeroByteSidecarIsEmptyNotAbsentForEachSource() throws {
        let limits = try Fixture.limits()
        let draftRefusal = Fixture.refusal(draft: Data(), connections: Fixture.connectionsBytes, limits: limits)
        let connectionsRefusal = Fixture.refusal(draft: Fixture.draftBytes, connections: Data(), limits: limits)
        let expectedDraft: LegacySidecarRefusal = .empty(.pendingDraft)
        let expectedConnections: LegacySidecarRefusal = .empty(.connections)
        #expect(draftRefusal == expectedDraft)
        #expect(connectionsRefusal == expectedConnections)
    }

    @Test
    func aOneByteWhitespaceSidecarIsUndecodableNotEmpty() throws {
        let limits = try Fixture.limits()
        for source in LegacySidecarSource.allCases {
            let refusal = Fixture.refusal(source: source, data: Fixture.text(" "), limits: limits)
            let expected: LegacySidecarRefusal = .undecodable(source)
            #expect(refusal == expected)
        }
    }

    // MARK: Content probes

    @Test
    func invalidUTF8BytesAreNotUTF8ForEachSourceWhetherLoneOverlongOrSurrogate() throws {
        let limits = try Fixture.limits()
        let variants = [Fixture.lone, Fixture.overlong, Fixture.surrogate]
        for source in LegacySidecarSource.allCases {
            for variant in variants {
                let refusal = Fixture.refusal(source: source, data: Fixture.invalidUTF8(variant), limits: limits)
                let expected: LegacySidecarRefusal = .notUTF8(source)
                #expect(refusal == expected)
            }
        }
    }

    @Test
    func textThatIsNotOneJSONValueIsUndecodableForEachSource() throws {
        let limits = try Fixture.limits()
        let bomPrefix: [UInt8] = [0xEF, 0xBB, 0xBF]
        let bomBody: [UInt8] = Array("{}".utf8)
        let bom = Data(bomPrefix + bomBody)
        let nul = Fixture.invalidUTF8([0x00])
        let deep = Fixture.text(String(repeating: "[", count: 600) + String(repeating: "]", count: 600))
        let variants: [Data] = [
            bom, nul, deep, Fixture.text(#"{"k":1,"k":2}"#), Fixture.text(#"{"k":1,}"#), Fixture.text(#"{"k":"#),
            Fixture.text("{"), Fixture.text("nope"), Fixture.text("{} {}")
        ]
        for source in LegacySidecarSource.allCases {
            for variant in variants {
                let refusal = Fixture.refusal(source: source, data: variant, limits: limits)
                let expected: LegacySidecarRefusal = .undecodable(source)
                #expect(refusal == expected)
            }
        }
    }

    @Test
    func aTopLevelThatIsNotAnObjectIsRefusedForEachSource() throws {
        let limits = try Fixture.limits()
        let tops = ["[]", "[1,2]", #""text""#, "5", "1.5", "null", "true", #"[{"k":1}]"#]
        for source in LegacySidecarSource.allCases {
            for top in tops {
                let refusal = Fixture.refusal(source: source, data: Fixture.text(top), limits: limits)
                let expected: LegacySidecarRefusal = .notAnObject(source)
                #expect(refusal == expected)
            }
        }
    }

    @Test
    func anyObjectIsAcceptedWithoutLookingAtItsContent() throws {
        let limits = try Fixture.limits()
        let objects = [
            "{}", "  {\"k\" : [1, {\"n\": null}]}\n",
            #"{"contract":"other","version":9}"#, #"{"unknown":{"deep":[[]]}}"#
        ]
        for text in objects {
            let data = Fixture.text(text)
            let plan = try LegacySidecarPlan.make(draft: data, connections: data, limits: limits)
            try #require(plan.files.count == 2)
            #expect(Array(plan.files[0].bytes) == Array(data))
            #expect(Array(plan.files[1].bytes) == Array(data))
        }
    }

    @Test
    func theSamePlanIsBuiltFromTheSameInputsEachTime() throws {
        let limits = try Fixture.limits()
        let first = try LegacySidecarPlan.make(
            draft: Fixture.draftBytes, connections: Fixture.connectionsBytes, limits: limits
        )
        let second = try LegacySidecarPlan.make(
            draft: Fixture.draftBytes, connections: Fixture.connectionsBytes, limits: limits
        )
        #expect(first == second)
        let other = try LegacySidecarPlan.make(draft: Fixture.draftBytes, connections: nil, limits: limits)
        #expect(first != other)
    }

    // MARK: Production sources

    static let sourceNames = [
        "LegacySidecarRefusal.swift", "LegacySidecarPlan.swift", "LegacySidecarPlan+Probe.swift",
        "LegacySidecarPlan+Compose.swift"
    ]

    /// The production files, read from the checkout or from the package mirror; empty when absent.
    static func productionSources() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Persistence/Adoption/Sidecars/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = sourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == sourceNames.count { return texts }
        }
        return []
    }

    @Test(.enabled(if: !LegacySidecarAdoptionTests.productionSources().isEmpty))
    func theFourProductionFilesContainNoneOfTheListedWordsOrImports() {
        let texts = Self.productionSources()
        #expect(texts.count == 4)
        let banned = [
            "FileManager", "Date", "Task", "Clock", "String(decoding", "default:", "URL(", "import SwiftUI",
            "import Combine", "DispatchQueue", "Observation", "HANDOFF", "DESIGN", "mutant", "LSC1"
        ]
        for text in texts {
            for word in banned { #expect(!text.contains(word)) }
        }
    }
}
