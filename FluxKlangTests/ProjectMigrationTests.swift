import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of the pure migration split: storage classes, independence, byte-exact originals, byte caps, absence,
/// payload-free refusals and the connections shapes `StudioConnectionsStore` loads. The Draft file extends this
/// suite and shares its fixtures.
@Suite(.productionAccessAudit)
struct ProjectMigrationTests {
    enum Fixture {
        static let moveID = "44444444-4444-4444-4444-444444444444"
        static let equipmentID = "55555555-5555-5555-5555-555555555555"
        static let draftID = "66666666-6666-6666-6666-666666666666"

        /// Odd spacing, unknown members, an escape, number spellings and a move with its verification evidence
        /// and lifecycle; all must survive byte for byte.
        static let connectionsBytes = Data([
            #"{ "connections" : {"home":{"inputs":[ {"id":"\#(moveID)","connector":3,"#,
            #""equipmentID":"\#(equipmentID)","outputPort":0} ],"outputs":[]},"temporaryMoves":[{"id":"\#(moveID)","#,
            #""equipmentID":"\#(equipmentID)","connections":{"inputs":[],"outputs":[]},"lifecycle":"active","#,
            #""verification":{"state":"verified","checkedAt":8.0E8,"expectedCount":2,"confirmedCount":2,"#,
            #""details":"caf\u00e9"},"activatedAt":800000000.50}], "x-future" : [1 , 2]},"#,
            #"  "initialized":true , "confirmedOutputDefaultsVersion":2 }"#, "\n"
        ].joined().utf8)

        static let usbMapBytes = Data([
            #"{"version":1, "mode" : "control","mapping":{"sourceNameContains":["Launch Control XL"],"#,
            #""channel":9,"faderCCs":[77,78],"panOrBalanceCCs":[],"selectCCs":[],"muteCCs":[],"#,
            #""bankPreviousCC":103,"bankNextCC":102}, "extra":1.50e0}"#, "\n"
        ].joined().utf8)

        static let draftBytes = Data([
            #"{"id":"\#(draftID)", "createdAt" : 800000000.5,"request":{"sourceInstrumentIDs":["\#(equipmentID)"],"#,
            #""effectChainIDs":[],"destination":{"mains":{}}},"fragment":{"nodes":[],"edges":[],"endpoints":[]},"#,
            #""validation":[],"liveReferences":[{"id":"live-ref-1"}],"outputReferences":[{"id":"output-ref-1"}],"#,
            #""nameReferences":[{"id":"name-ref-1","kind":"excludedEffect"}]}"#, "\n"
        ].joined().utf8)

        static func limits(entryBytes: Int = 65_536, totalBytes: Int = 262_144) throws -> ProjectPackageLimits {
            try ProjectPackageLimits(
                maxEntries: 32, maxDepth: 8, maxPathUTF8Bytes: 256, maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            )
        }

        static func text(_ text: String) -> Data { Data(text.utf8) }

        /// `bytes` followed by trailing spaces up to exactly `count` bytes: still one JSON value.
        static func padded(_ bytes: Data, to count: Int) -> Data {
            bytes + Data(repeating: 0x20, count: count - bytes.count)
        }

        /// Not UTF-8 at all, so any decoding attempt is `undecodable`, never `oversized`.
        static func notUTF8(count: Int) -> Data { Data(repeating: 0xFF, count: count) }

        static func valid(_ source: ProjectMigrationSource) -> Data {
            switch source {
            case .connections: connectionsBytes
            case .usbMap: usbMapBytes
            case .pendingDraft: draftBytes
            }
        }

        /// The split of `data` supplied as `source` alone.
        static func split(_ source: ProjectMigrationSource, _ data: Data, limits: ProjectPackageLimits)
            -> ProjectMigrationSplit {
            ProjectMigration.split(
                connections: source == .connections ? data : nil, usbMap: source == .usbMap ? data : nil,
                draft: source == .pendingDraft ? data : nil, limits: limits
            )
        }

        /// The refusal of `data` supplied as `source` alone, or nil when it is accepted (or absent).
        static func refusal(_ source: ProjectMigrationSource, _ data: Data, limits: ProjectPackageLimits)
            -> ProjectMigrationRefusal? {
            let result = split(source, data, limits: limits)
            switch source {
            case .connections: return failure(result.homeWiring)
            case .usbMap: return failure(result.hostLocal)
            case .pendingDraft: return failure(result.draft)
            }
        }

        static func failure<Value>(_ result: Result<Value, ProjectMigrationRefusal>?) -> ProjectMigrationRefusal? {
            guard case .failure(let refusal)? = result else { return nil }
            return refusal
        }

        static func success<Value>(_ result: Result<Value, ProjectMigrationRefusal>?) -> Value? {
            guard case .success(let value)? = result else { return nil }
            return value
        }
    }

    // MARK: Classes and policy

    @Test
    func eachPartCarriesTheStorageClassTheInventoryGivesItsFile() throws {
        let split = ProjectMigration.split(
            connections: Fixture.connectionsBytes, usbMap: Fixture.usbMapBytes, draft: Fixture.draftBytes,
            limits: try Fixture.limits()
        )
        let home = try #require(Fixture.success(split.homeWiring))
        let usb = try #require(Fixture.success(split.hostLocal))
        let draft = try #require(Fixture.success(split.draft))
        #expect(home.storageClass == .homeWiring)
        #expect(home.source == .connections)
        #expect(usb.storageClass == .hostLocalRoute)
        #expect(usb.source == .usbMap)
        #expect(draft.storageClass == .draft)
        let inventory: [(StorageSurface, StorageClass)] = [
            (StorageSurface(kind: .storeFile, name: "studio-connections.json"), home.storageClass),
            (StorageSurface(kind: .storeFile, name: "launch-control-xl.json"), usb.storageClass),
            (StorageSurface(kind: .localFile, name: "assistant-pending-studio-draft.json"), draft.storageClass)
        ]
        for (surface, storageClass) in inventory {
            #expect(StorageInventory.classification(of: surface) == storageClass)
        }
    }

    @Test
    func storagePolicyAllowsOnlyTheHomePartInKeyValueStorage() throws {
        let split = ProjectMigration.split(
            connections: Fixture.connectionsBytes, usbMap: Fixture.usbMapBytes, draft: Fixture.draftBytes,
            limits: try Fixture.limits()
        )
        let home = try #require(Fixture.success(split.homeWiring))
        let usb = try #require(Fixture.success(split.hostLocal))
        let draft = try #require(Fixture.success(split.draft))
        #expect(StoragePolicy.isKeyValueEligible(home.storageClass))
        #expect(!StoragePolicy.isKeyValueEligible(usb.storageClass))
        #expect(!StoragePolicy.isKeyValueEligible(draft.storageClass))
        #expect(StoragePolicy.permittedLocations(for: usb.storageClass) == [.localFile])
        #expect(StoragePolicy.permittedLocations(for: draft.storageClass) == [.localFile])
        let allowlist = KeyValueAllowlist.shipped
        #expect(allowlist.contains(rawKey: try KeyValueKey.storeFile(named: "studio-connections.json").rawValue))
        #expect(!allowlist.contains(rawKey: try KeyValueKey.storeFile(named: "launch-control-xl.json").rawValue))
    }

    // MARK: Independence

    @Test
    func aCorruptUSBMapStillYieldsTheHomePartAndTheDraft() throws {
        let limits = try Fixture.limits()
        for corrupt in ["{", "[]", #"{"version":1,"mode":"party","mapping":{}}"#] {
            let split = ProjectMigration.split(
                connections: Fixture.connectionsBytes, usbMap: Fixture.text(corrupt), draft: Fixture.draftBytes,
                limits: limits
            )
            #expect(Fixture.success(split.homeWiring).map { Array($0.original) } == Array(Fixture.connectionsBytes))
            #expect(Fixture.success(split.draft).map { Array($0.original) } == Array(Fixture.draftBytes))
            #expect(Fixture.failure(split.hostLocal)?.source == .usbMap)
        }
    }

    @Test
    func corruptConnectionsStillYieldTheUSBMapAndTheDraft() throws {
        let limits = try Fixture.limits()
        for corrupt in ["{", #"{"connections":[]}"#, "{}"] {
            let split = ProjectMigration.split(
                connections: Fixture.text(corrupt), usbMap: Fixture.usbMapBytes, draft: Fixture.draftBytes,
                limits: limits
            )
            #expect(Fixture.success(split.hostLocal).map { Array($0.original) } == Array(Fixture.usbMapBytes))
            #expect(Fixture.success(split.draft).map { Array($0.original) } == Array(Fixture.draftBytes))
            #expect(Fixture.failure(split.homeWiring)?.source == .connections)
        }
    }

    @Test
    func aCorruptDraftStillYieldsTheHomePartAndTheUSBMap() throws {
        let limits = try Fixture.limits()
        let corrupt: [(String, ProjectMigrationRefusalKind)] = [
            ("{", .undecodable), ("[]", .unsupportedShape),
            (#"{"id":"not-a-uuid","createdAt":0,"request":{},"fragment":{}}"#, .unsupportedShape)
        ]
        for (text, kind) in corrupt {
            let split = ProjectMigration.split(
                connections: Fixture.connectionsBytes, usbMap: Fixture.usbMapBytes, draft: Fixture.text(text),
                limits: limits
            )
            #expect(Fixture.success(split.homeWiring).map { Array($0.original) } == Array(Fixture.connectionsBytes))
            #expect(Fixture.success(split.hostLocal).map { Array($0.original) } == Array(Fixture.usbMapBytes))
            let expected = ProjectMigrationRefusal(source: .pendingDraft, kind: kind)
            #expect(Fixture.failure(split.draft) == expected, "\(text)")
        }
    }

    // MARK: Byte-exact originals

    @Test
    func originalsWithOddSpacingUnknownMembersAndMovesSurviveByteForByte() throws {
        let split = ProjectMigration.split(
            connections: Fixture.connectionsBytes, usbMap: Fixture.usbMapBytes, draft: nil,
            limits: try Fixture.limits()
        )
        let home = try #require(Fixture.success(split.homeWiring))
        let usb = try #require(Fixture.success(split.hostLocal))
        #expect(Array(home.original) == Array(Fixture.connectionsBytes))
        #expect(Array(usb.original) == Array(Fixture.usbMapBytes))
        for source in [Fixture.connectionsBytes, Fixture.usbMapBytes] {
            let reencoded = try ContractCoding.makeEncoder().encode(ContractCoding.decode(JSONValue.self, from: source))
            #expect(Array(reencoded) != Array(source))
        }
        let text = try #require(String(data: home.original, encoding: .utf8))
        for kept in [#""lifecycle":"active""#, #""checkedAt":8.0E8"#, #""activatedAt":800000000.50"#, "caf\\u00e9"] {
            #expect(text.contains(kept))
        }
    }

    // MARK: Byte caps

    @Test
    func eachSourceAtTheEntryCapIsAcceptedAndOneByteMoreIsOversized() throws {
        let limits = try Fixture.limits(entryBytes: 2000, totalBytes: 10_000)
        for source in ProjectMigrationSource.allCases {
            let atCap = Fixture.padded(Fixture.valid(source), to: 2000)
            #expect(Fixture.refusal(source, atCap, limits: limits) == nil)
            let overCap = Fixture.padded(Fixture.valid(source), to: 2001)
            let expected = ProjectMigrationRefusal(source: source, kind: .oversized)
            #expect(Fixture.refusal(source, overCap, limits: limits) == expected)
        }
    }

    @Test
    func anOversizedSourceIsRefusedBeforeAnyDecoding() throws {
        let limits = try Fixture.limits(entryBytes: 2000, totalBytes: 10_000)
        for source in ProjectMigrationSource.allCases {
            let atCap = Fixture.refusal(source, Fixture.notUTF8(count: 2000), limits: limits)
            #expect(atCap == ProjectMigrationRefusal(source: source, kind: .undecodable))
            let overCap = Fixture.refusal(source, Fixture.notUTF8(count: 2001), limits: limits)
            #expect(overCap == ProjectMigrationRefusal(source: source, kind: .oversized))
        }
    }

    @Test
    func theFourMiBDocumentCeilingBoundsEachSourceWhenTheEntryCapIsAboveIt() throws {
        let ceiling = ProjectGraphLimits.documentBytes
        let limits = try Fixture.limits(entryBytes: ceiling * 2, totalBytes: ceiling * 4)
        for source in ProjectMigrationSource.allCases {
            let overCeiling = Fixture.refusal(source, Fixture.notUTF8(count: ceiling + 1), limits: limits)
            #expect(overCeiling == ProjectMigrationRefusal(source: source, kind: .oversized))
            #expect(Fixture.refusal(source, Fixture.padded(Fixture.valid(source), to: ceiling), limits: limits) == nil)
        }
    }

    // MARK: Absence and refusals

    @Test
    func aMissingSourceGivesANilPartNotARefusal() throws {
        let limits = try Fixture.limits()
        let none = ProjectMigration.split(connections: nil, usbMap: nil, draft: nil, limits: limits)
        #expect(none.homeWiring == nil)
        #expect(none.hostLocal == nil)
        #expect(none.draft == nil)
        for source in ProjectMigrationSource.allCases {
            let split = Fixture.split(source, Fixture.valid(source), limits: limits)
            #expect((split.homeWiring == nil) == (source != .connections))
            #expect((split.hostLocal == nil) == (source != .usbMap))
            #expect((split.draft == nil) == (source != .pendingDraft))
        }
        let empty = ProjectMigration.split(connections: Data(), usbMap: Data(), draft: Data(), limits: limits)
        #expect(Fixture.failure(empty.homeWiring)?.kind == .undecodable)
        #expect(Fixture.failure(empty.hostLocal)?.kind == .undecodable)
        #expect(Fixture.failure(empty.draft)?.kind == .undecodable)
    }

    @Test
    func refusalsCarryOnlyTheirSourceAndKindAndNoPayload() throws {
        let limits = try Fixture.limits()
        let secret = Fixture.text(#"{"SECRET-PAYLOAD":"/Users/someone/private.json"}"#)
        for source in ProjectMigrationSource.allCases {
            let refusal = try #require(Fixture.refusal(source, secret, limits: limits))
            #expect(refusal == ProjectMigrationRefusal(source: source, kind: .unsupportedShape))
            #expect(Mirror(reflecting: refusal).children.map(\.label) == ["source", "kind"])
            let described = String(describing: refusal) + String(reflecting: refusal)
            #expect(!described.contains("SECRET"))
            #expect(!described.contains("/Users"))
        }
    }

    // MARK: Connections shapes (StudioConnectionsStore.Persisted)

    @Test
    func everyConnectionsShapeTheStoreLoadsIsAcceptedWithItsBytes() throws {
        let limits = try Fixture.limits()
        let accepted = [
            #"{"connections":{}}"#,
            #"{"connections":{},"initialized":null,"confirmedOutputDefaultsVersion":null}"#,
            #"{"connections":{},"initialized":false,"confirmedOutputDefaultsVersion":-3}"#,
            #"{"connections":{"home":null,"temporaryMoves":null,"migrationIssues":null}}"#,
            #"{"connections":{"home":{"inputs":[],"outputs":[]},"temporaryMoves":[],"migrationIssues":[]}}"#,
            #"{"connections":{"home":{"inputs":[],"outputs":[],"later":1},"future":{}},"unknown":[true]}"#,
            #"{"connections":{},"confirmedOutputDefaultsVersion":2.0}"#
        ]
        for text in accepted {
            let data = Fixture.text(text)
            let split = Fixture.split(.connections, data, limits: limits)
            #expect(Fixture.success(split.homeWiring).map { Array($0.original) } == Array(data), "\(text)")
        }
    }

    @Test
    func everyOtherConnectionsShapeIsAnUnsupportedShape() throws {
        let limits = try Fixture.limits()
        let refused = [
            "{}", "[]", "null", "1", #""connections""#, #"{"connections":null}"#, #"{"connections":[]}"#,
            #"{"connections":"home"}"#, #"{"connections":{},"initialized":"yes"}"#,
            #"{"connections":{},"initialized":1}"#, #"{"connections":{},"confirmedOutputDefaultsVersion":1.5}"#,
            #"{"connections":{},"confirmedOutputDefaultsVersion":"2"}"#,
            #"{"connections":{},"confirmedOutputDefaultsVersion":18446744073709551615}"#,
            #"{"connections":{"home":[]}}"#, #"{"connections":{"home":{}}}"#,
            #"{"connections":{"home":{"inputs":[]}}}"#, #"{"connections":{"home":{"inputs":[],"outputs":null}}}"#,
            #"{"connections":{"temporaryMoves":{}}}"#, #"{"connections":{"migrationIssues":"none"}}"#
        ]
        for text in refused {
            let refusal = Fixture.refusal(.connections, Fixture.text(text), limits: limits)
            #expect(refusal == ProjectMigrationRefusal(source: .connections, kind: .unsupportedShape), "\(text)")
        }
    }

    @Test
    func eachUSBMapFieldIsCheckedOnItsOwn() throws {
        let limits = try Fixture.limits()
        for mode in LaunchControlXLMode.allCases {
            let data = Fixture.text(#"{"version":-2,"mode":"\#(mode.rawValue)","mapping":{"later":null}}"#)
            let split = Fixture.split(.usbMap, data, limits: limits)
            #expect(Fixture.success(split.hostLocal).map { Array($0.original) } == Array(data), "\(mode)")
        }
        let refused = [
            #"{"mode":"control","mapping":{}}"#, #"{"version":null,"mode":"control","mapping":{}}"#,
            #"{"version":"1","mode":"control","mapping":{}}"#, #"{"version":1.5,"mode":"control","mapping":{}}"#,
            #"{"version":18446744073709551615,"mode":"control","mapping":{}}"#,
            #"{"version":1,"mapping":{}}"#, #"{"version":1,"mode":null,"mapping":{}}"#,
            #"{"version":1,"mode":"Control","mapping":{}}"#,
            #"{"version":1,"mode":"control"}"#, #"{"version":1,"mode":"control","mapping":null}"#,
            #"{"version":1,"mode":"control","mapping":[]}"#, #"{"version":1,"mode":"control","mapping":"all"}"#
        ]
        for text in refused {
            let refusal = Fixture.refusal(.usbMap, Fixture.text(text), limits: limits)
            #expect(refusal == ProjectMigrationRefusal(source: .usbMap, kind: .unsupportedShape), "\(text)")
        }
    }

    @Test
    func strictDecodingRefusesWhatAPlainDecoderWouldKeep() throws {
        let limits = try Fixture.limits()
        let bomPrefix: [UInt8] = [0xEF, 0xBB, 0xBF]
        let variants = [
            Data(bomPrefix + Array(#"{"connections":{}}"#.utf8)),
            Fixture.text(#"{"connections":{},"connections":{}}"#),
            Fixture.text(#"{"connections":{},}"#),
            Data(Array(#"{"connections":{},"k":""#.utf8) + [0xC3] + Array(#""}"#.utf8))
        ]
        for variant in variants {
            let refusal = Fixture.refusal(.connections, variant, limits: limits)
            #expect(refusal == ProjectMigrationRefusal(source: .connections, kind: .undecodable))
        }
    }
}
