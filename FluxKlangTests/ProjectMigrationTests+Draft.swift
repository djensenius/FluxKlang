import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The migrated draft: inert data with its identity, original bytes and invalidated provenance, and no way back
/// to an authoritative `StudioPatchDraft`.
extension ProjectMigrationTests {
    @Test
    func aMigratedDraftKeepsItsIDCreatedAtAndBytesWithInvalidatedProvenance() throws {
        let split = ProjectMigration.split(
            connections: nil, usbMap: nil, draft: Fixture.draftBytes, limits: try Fixture.limits()
        )
        let draft = try #require(Fixture.success(split.draft))
        #expect(draft.id == UUID(uuidString: Fixture.draftID))
        #expect(draft.createdAt == Date(timeIntervalSinceReferenceDate: 800_000_000.5))
        #expect(Array(draft.original) == Array(Fixture.draftBytes))
        let expected: JSONValue = .object([
            "source": .string("PendingStudioDraft"), "authority": .string("invalidated"), "reviewRequired": .bool(true)
        ])
        #expect(draft.provenance == expected)
        #expect(MigratedDraft.provenance == expected)
    }

    @Test
    func aMigratedDraftNeverStripsItsReferences() throws {
        let split = ProjectMigration.split(
            connections: nil, usbMap: nil, draft: Fixture.draftBytes, limits: try Fixture.limits()
        )
        let draft = try #require(Fixture.success(split.draft))
        let value = try ContractCoding.decode(JSONValue.self, from: draft.original)
        guard case .object(let fields) = value else {
            Issue.record("The retained draft is not an object")
            return
        }
        #expect(fields["liveReferences"] == .array([.object(["id": .string("live-ref-1")])]))
        #expect(fields["outputReferences"] == .array([.object(["id": .string("output-ref-1")])]))
        let name: JSONValue = .object(["id": .string("name-ref-1"), "kind": .string("excludedEffect")])
        #expect(fields["nameReferences"] == .array([name]))
        #expect(fields["validation"] == .array([]))
    }

    @Test
    func aMigratedDraftHoldsOnlyInertDataAndIsNotDecodable() throws {
        let split = ProjectMigration.split(
            connections: nil, usbMap: nil, draft: Fixture.draftBytes, limits: try Fixture.limits()
        )
        let draft = try #require(Fixture.success(split.draft))
        #expect(Mirror(reflecting: draft).children.map(\.label) == ["original", "id", "createdAt"])
        #expect(!(draft as Any is any Decodable))
    }

    @Test
    func eachDraftShapeStudioPatchDraftRequiresIsAccepted() throws {
        let limits = try Fixture.limits()
        let id = Fixture.draftID
        let accepted = [
            #"{"id":"\#(id)","createdAt":0,"request":{},"fragment":{}}"#,
            #"{"id":"\#(id.lowercased())","createdAt":-1.25,"request":{"x":1},"fragment":{},"other":null}"#,
            #"{"id":"\#(id)","createdAt":18446744073709551615,"request":{},"fragment":{}}"#
        ]
        for text in accepted {
            let split = Fixture.split(.pendingDraft, Fixture.text(text), limits: limits)
            #expect(Fixture.success(split.draft)?.id == UUID(uuidString: id), "\(text)")
        }
    }

    @Test
    func everyOtherDraftShapeIsAnUnsupportedShape() throws {
        let limits = try Fixture.limits()
        let id = Fixture.draftID
        let refused = [
            "[]", "null", #"{}"#, #"{"createdAt":0,"request":{},"fragment":{}}"#,
            #"{"id":"not-a-uuid","createdAt":0,"request":{},"fragment":{}}"#,
            #"{"id":7,"createdAt":0,"request":{},"fragment":{}}"#,
            #"{"id":"\#(id)","request":{},"fragment":{}}"#,
            #"{"id":"\#(id)","createdAt":"2026-01-01","request":{},"fragment":{}}"#,
            #"{"id":"\#(id)","createdAt":null,"request":{},"fragment":{}}"#,
            #"{"id":"\#(id)","createdAt":0,"fragment":{}}"#,
            #"{"id":"\#(id)","createdAt":0,"request":[],"fragment":{}}"#,
            #"{"id":"\#(id)","createdAt":0,"request":{}}"#,
            #"{"id":"\#(id)","createdAt":0,"request":{},"fragment":null}"#
        ]
        for text in refused {
            let refusal = Fixture.refusal(.pendingDraft, Fixture.text(text), limits: limits)
            #expect(refusal == ProjectMigrationRefusal(source: .pendingDraft, kind: .unsupportedShape), "\(text)")
        }
    }

    // MARK: Production sources

    static let migrationSourceNames = [
        "ProjectMigration.swift", "ProjectMigration+Shapes.swift", "ProjectMigrationRefusal.swift",
        "MigratedDraft.swift"
    ]

    /// The production files, read from the checkout or from the package mirror; empty when absent.
    static func migrationSources() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Persistence/Adoption/Migration/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = migrationSourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == migrationSourceNames.count { return texts }
        }
        return []
    }

    /// The absence D2 requires: no code path builds a `StudioPatchDraft`, decodes one or reaches its store, and
    /// nothing touches files, iCloud or app wiring.
    @Test(.enabled(if: !ProjectMigrationTests.migrationSources().isEmpty))
    func theMigrationFilesHaveNoPathBackToAnAuthoritativeDraft() {
        let texts = Self.migrationSources()
        #expect(texts.count == 4)
        let banned = [
            "StudioPatchDraft(", "StudioPatchDraft.self", "JSONDecoder()", ".save(", "PendingStudioPatchPersisting",
            "PendingStudioPatchStore(", "FileManager", "URL(", "NSUbiquitousKeyValueStore", "JSONFileStore",
            "AppPersistence", "import SwiftUI", "Observation", "default:"
        ]
        for text in texts {
            for word in banned { #expect(!text.contains(word), "\(word)") }
        }
    }
}
