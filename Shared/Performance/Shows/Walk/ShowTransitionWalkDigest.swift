//
//  ShowTransitionWalkDigest.swift
//  FluxKlang
//
//  The compact result of walking a setlist: one row per stop (#106 STW1). A digest reports the planner's blocks
//  per boundary and judges nothing.
//

/// One stop of the walk. `loaded` is the patch the walk ASSUMES is loaded before this move (the starting patch plus
/// planned recalls), not device state. `blocks` are the planner's, in its order: patch, action set, chart.
struct ShowTransitionWalkRow: Equatable, Sendable {
    /// `nil` on the opening stop, which has no predecessor.
    let from: ShowStopReference?
    let to: ShowStopReference
    let loaded: ShowActivePatch?
    let blocks: [ShowTransitionBlock]

    /// The planner found no block. This says nothing about whether an action set is ready.
    var isClear: Bool { blocks.isEmpty }
}

/// The rows of one setlist in cursor order (the opening stop first) and what the walk cost. Rows are compact: they
/// hold ids and blocks, and carry no recall changes, readiness reports or titles.
struct ShowTransitionWalkDigest: Equatable, Sendable {
    let setlist: SetlistID
    let rows: [ShowTransitionWalkRow]
    /// Distinct planner invocations (memo misses): a cost receipt, and part of equality.
    let plannerRuns: Int

    var stopCount: Int { rows.count }
    /// Rows with at least one block, not the number of blocks.
    var blockedCount: Int { rows.filter { !$0.isClear }.count }
    /// Rows whose first block is a structural activation review.
    var structuralReviewCount: Int { rows.filter { Self.opensWithReview($0) }.count }

    private static func opensWithReview(_ row: ShowTransitionWalkRow) -> Bool {
        guard let first = row.blocks.first else { return false }
        if case .requiresStructuralActivationReview = first { return true }
        return false
    }
}
