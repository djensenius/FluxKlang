import Foundation

/// A review-only description of the archived legacy draft (#122). Pure and inert: every field is derived from a
/// `MigratedDraft` and the launch state, none holds the draft's bytes or content, and nothing here can apply, send or
/// emit anything. `canApply` is a constant `false`. The draft's request and fragment text are never read.
struct ArchivedDraftReview: Sendable, Equatable {
    /// How the archived draft stands, one case per `LegacyDraftLaunchState`. Text for each is the caller's.
    enum Status: Sendable, Equatable {
        case notArchived
        case awaitingRetirement
        case retired
        case goneFromDisk
        case replacedAtOriginalName
        case retiredNameOccupied
    }

    let draftID: UUID
    let createdAt: Date
    /// The size of the archived original, in bytes.
    let byteCount: Int
    let launch: LegacyDraftLaunchState
    /// The provenance members as read, or empty and `true` when `isRecognized` is false.
    let source: String
    let authority: String
    let reviewRequired: Bool
    /// True only when the provenance has the expected shape and marks the draft invalidated and review-required.
    let isRecognized: Bool

    /// The archived draft never applies.
    var canApply: Bool { false }

    var status: Status {
        switch launch {
        case .noDraftArchived: .notArchived
        case .pending: .awaitingRetirement
        case .retired: .retired
        case .draftGone: .goneFromDisk
        case .draftChanged: .replacedAtOriginalName
        case .retiredNameOccupied: .retiredNameOccupied
        }
    }

    static func make(draft: MigratedDraft, launch: LegacyDraftLaunchState) -> ArchivedDraftReview {
        make(draft: draft, launch: launch, provenance: draft.provenance)
    }

    /// The review of the receipt's adopted draft, or nil when the receipt archived none.
    static func make(receipt: LegacyMigrationReceipt, launch: LegacyDraftLaunchState) -> ArchivedDraftReview? {
        guard case .adopted(let draft) = receipt.report.draft else { return nil }
        return make(draft: draft, launch: launch)
    }

    /// Reads `provenance` defensively; a value that is not the expected marker is not trusted.
    static func make(
        draft: MigratedDraft, launch: LegacyDraftLaunchState, provenance: JSONValue
    ) -> ArchivedDraftReview {
        var source = ""
        var authority = ""
        var reviewRequired = true
        var isRecognized = false
        if case .object(let fields) = provenance,
           case .string(let readSource)? = fields["source"],
           case .string(let readAuthority)? = fields["authority"],
           case .bool(let readReview)? = fields["reviewRequired"],
           readSource == "PendingStudioDraft", readAuthority == "invalidated", readReview {
            source = readSource
            authority = readAuthority
            reviewRequired = readReview
            isRecognized = true
        }
        return ArchivedDraftReview(
            draftID: draft.id, createdAt: draft.createdAt, byteCount: draft.original.count, launch: launch,
            source: source, authority: authority, reviewRequired: reviewRequired, isRecognized: isRecognized
        )
    }
}
