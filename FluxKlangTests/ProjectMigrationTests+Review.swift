import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `ArchivedDraftReview`: the review-only description of the archived draft. It reads the provenance, never the
/// draft's content, and can never apply.
extension ProjectMigrationTests {
    enum Review {
        /// Every `LegacyDraftLaunchState` case. The enum is not `CaseIterable`, so this list is kept by hand; the
        /// exhaustive switch in `expectedStatus(_:)` stops this file building when a case is added, and a new case
        /// must be added here at the same time.
        static let states: [LegacyDraftLaunchState] = [
            .noDraftArchived, .pending, .retired, .draftGone, .draftChanged, .retiredNameOccupied
        ]

        /// The display status each launch state must show. Exhaustive on purpose: see `states`.
        static func expectedStatus(_ launch: LegacyDraftLaunchState) -> ArchivedDraftReview.Status {
            switch launch {
            case .noDraftArchived: .notArchived
            case .pending: .awaitingRetirement
            case .retired: .retired
            case .draftGone: .goneFromDisk
            case .draftChanged: .replacedAtOriginalName
            case .retiredNameOccupied: .retiredNameOccupied
            }
        }

        /// Compiles only for a `Sendable` value.
        static func requireSendable(_: some Sendable) {}

        static func draft() throws -> MigratedDraft {
            let split = ProjectMigration.split(
                connections: nil, usbMap: nil, draft: Fixture.draftBytes, limits: try Fixture.limits()
            )
            return try #require(Fixture.success(split.draft))
        }

        /// The review file's text, read from the checkout or from the package mirror; nil when absent.
        static func source() -> String? {
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let relative = "Shared/Persistence/Adoption/Migration/ArchivedDraftReview.swift"
            let parent = folder.deletingLastPathComponent()
            for root in [parent, parent.deletingLastPathComponent()] {
                for prefix in ["", "Sources/FluxKlang/"] {
                    let url = root.appendingPathComponent(prefix + relative)
                    if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
                }
            }
            return nil
        }
    }

    @Test
    func anArchivedDraftReviewCanNeverApplyInAnyLaunchState() throws {
        let draft = try Review.draft()
        for launch in Review.states {
            #expect(!ArchivedDraftReview.make(draft: draft, launch: launch).canApply, "\(launch)")
        }
    }

    @Test
    func anArchivedDraftReviewReadsTheProvenanceAndTheDraftIdentity() throws {
        let draft = try Review.draft()
        let review = ArchivedDraftReview.make(draft: draft, launch: .pending)
        #expect(review.draftID == UUID(uuidString: Fixture.draftID))
        #expect(review.createdAt == Date(timeIntervalSinceReferenceDate: 800_000_000.5))
        #expect(review.byteCount == Fixture.draftBytes.count)
        #expect(review.source == "PendingStudioDraft")
        #expect(review.authority == "invalidated")
        #expect(review.reviewRequired)
        #expect(review.isRecognized)
        #expect(review.launch == .pending)
    }

    @Test
    func anArchivedDraftReviewDoesNotTrustAnUnrecognisedProvenance() throws {
        let draft = try Review.draft()
        let marker: [String: JSONValue] = [
            "source": .string("PendingStudioDraft"), "authority": .string("invalidated"), "reviewRequired": .bool(true)
        ]
        func altered(_ key: String, _ value: JSONValue?) -> JSONValue {
            var fields = marker
            fields[key] = value
            return .object(fields)
        }
        let unrecognised: [JSONValue] = [
            .null, .array([]), .object([:]), .string("invalidated"),
            altered("authority", .string("granted")), altered("authority", .bool(true)),
            altered("source", .string("Other")), altered("source", nil),
            altered("reviewRequired", .bool(false)), altered("reviewRequired", .string("true")),
            altered("reviewRequired", nil)
        ]
        for provenance in unrecognised {
            let review = ArchivedDraftReview.make(draft: draft, launch: .pending, provenance: provenance)
            #expect(!review.isRecognized, "\(provenance)")
            #expect(review.source.isEmpty && review.authority.isEmpty && review.reviewRequired, "\(provenance)")
            #expect(!review.canApply, "\(provenance)")
        }
        let extra = ArchivedDraftReview.make(draft: draft, launch: .pending, provenance: altered("note", .int(1)))
        #expect(extra.isRecognized)
    }

    @Test
    func eachLaunchStateMapsToItsOwnDisplayStatus() throws {
        let draft = try Review.draft()
        let expected = Review.states.map { ($0, Review.expectedStatus($0)) }
        for (launch, status) in expected {
            #expect(ArchivedDraftReview.make(draft: draft, launch: launch).status == status, "\(launch)")
        }
        for (index, left) in expected.enumerated() {
            for right in expected[(index + 1)...] { #expect(left.1 != right.1, "\(left.0) \(right.0)") }
        }
    }

    @Test
    func aReceiptWithADraftYieldsAReviewAndOneWithoutYieldsNone() throws {
        var store = Legacy.volume()
        let receipt = try #require(Archive.archived(try Archive.run(&store)))
        let review = try #require(ArchivedDraftReview.make(receipt: receipt, launch: .retired))
        #expect(review == ArchivedDraftReview.make(draft: try Review.draft(), launch: .retired))

        var homeOnly = Legacy.volume([Legacy.connections: Fixture.connectionsBytes])
        let noDraft = try #require(Archive.archived(try Archive.run(&homeOnly)))
        #expect(ArchivedDraftReview.make(receipt: noDraft, launch: .noDraftArchived) == nil)
    }

    @Test
    func anArchivedDraftReviewHoldsOnlyDerivedValuesAndIsEquatable() throws {
        let draft = try Review.draft()
        let review = ArchivedDraftReview.make(draft: draft, launch: .draftGone)
        #expect(Mirror(reflecting: review).children.map(\.label) == [
            "draftID", "createdAt", "byteCount", "launch", "source", "authority", "reviewRequired", "isRecognized"
        ])
        #expect(review == ArchivedDraftReview.make(draft: draft, launch: .draftGone))
        #expect(review != ArchivedDraftReview.make(draft: draft, launch: .pending))
        Review.requireSendable(review)
    }

    @Test
    func theReviewSourceNamesNoDraftStoreAssistantOrHardwareType() throws {
        let text = try #require(Review.source())
        let forbidden = [
            "StudioPatchDraft", "PendingStudioPatchStore", "PendingStudioPatchReviewView", "AssistantCore",
            "WingController", "Transport", "CoreMIDI", "SwiftUI", "FileManager", "JSONDecoder", "ContractCoding"
        ]
        for name in forbidden { #expect(!text.contains(name), "\(name)") }
        #expect(!text.contains("Data"))
        #expect(text.components(separatedBy: "draft.original").count == 2)
        #expect(text.contains("draft.original.count"))
    }
}
