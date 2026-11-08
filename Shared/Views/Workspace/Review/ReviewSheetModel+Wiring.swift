//
//  ReviewSheetModel+Wiring.swift
//  FluxKlang
//
//  The `WiringReviewDiff` adapter of the review sheet (#99 RV1): the rows of a diff, and the stale state taken from
//  `WiringStaleDraft.check`. The diff is read, never built or changed here.
//

extension ReviewRowKind {
    init(_ kind: WiringReviewChangeKind) {
        switch kind {
        case .addedNode: self = .addedNode
        case .movedNode: self = .movedNode
        case .removedNode: self = .removedNode
        case .addedEdge: self = .addedEdge
        case .removedEdge: self = .removedEdge
        }
    }
}

extension ReviewRow {
    /// The number of changes of `diff`, counted without building a row.
    static func changeCount(of diff: WiringReviewDiff) -> Int {
        diff.groups.reduce(0) { $0 + $1.changes.count }
    }

    /// One row per change, in the diff's own order (groups in kind order, ids sorted inside a group).
    static func changeRows(of diff: WiringReviewDiff) -> [ReviewRow] {
        diff.changes.map(ReviewRow.change)
    }
}

/// Whether a revalidation of the stale draft can be started.
enum ReviewRevalidation: Hashable, Sendable {
    case available
    case inProgress
}

/// Whether the draft under review is stale, taken from `WiringStaleDraft.check(_:active:)`.
enum ReviewStaleness: Hashable, Sendable {
    case fresh
    case stale(WiringStaleDraft, revalidate: ReviewRevalidation)

    /// `.fresh` for a `nil` check, else the stale report with its revalidate state.
    static func from(check: WiringStaleDraft?, revalidate: ReviewRevalidation) -> ReviewStaleness {
        guard let check else { return .fresh }
        return .stale(check, revalidate: revalidate)
    }

    var banner: ReviewStaleBanner? {
        switch self {
        case .fresh: nil
        case .stale(let report, let revalidate): ReviewStaleBanner(report: report, revalidate: revalidate)
        }
    }
}

/// The banner of a stale review: "Based on rev 42; active is 43" and the revalidate state.
struct ReviewStaleBanner: Hashable, Sendable {
    let draft: DraftID
    let baseRevision: ContractRevision
    let activeRevision: ContractRevision
    let revalidate: ReviewRevalidation
    /// `WiringStaleDraft.description`: fixed wording plus the two revision numbers ("Based on rev X; active is Y").
    let message: String

    fileprivate init(report: WiringStaleDraft, revalidate: ReviewRevalidation) {
        draft = report.draft
        baseRevision = report.baseRevision
        activeRevision = report.activeRevision
        self.revalidate = revalidate
        message = report.description
    }
}
