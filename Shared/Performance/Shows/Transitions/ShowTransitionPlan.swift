//
//  ShowTransitionPlan.swift
//  FluxKlang
//
//  What moving from one `ShowStop` to the next would do, for review only
//  (#106 SH2): a patch variation recall within one patch, an action set to arm
//  with its readiness, and the target's chart. Building a plan recalls, arms,
//  fires and opens nothing. Anything that cannot be planned is a typed block,
//  never hidden and never attempted.
//

/// A stop named by stable IDs only, so a plan never depends on setlist order.
struct ShowStopReference: Hashable, Sendable {
    let position: ShowPosition
    let song: SongID

    init(_ stop: ShowStop) {
        position = stop.position
        song = stop.song
    }
}

/// Why one item of a transition cannot be planned.
enum ShowTransitionBlock: Equatable, Sendable {
    /// The target links a different patch than the one actually loaded (`from`), or nothing is loaded
    /// (`from == nil`). Activating another patch may restructure audio, which needs the structural activation
    /// review path (#62); it is not attempted here.
    case requiresStructuralActivationReview(from: PatchID?, to: PatchID)
    /// A target link that does not resolve, in the show's own vocabulary. Kept, reported and fixed by relinking.
    case unresolvedLink(ShowLinkProblem)
    /// `PatchRecallPlanner` refused the same-patch recall, including an active variation the patch no longer has.
    case patchRecallRefused(PatchID, PatchVariationError)
    /// The linked action set did not resolve against the project's actions.
    case actionSetRefused(ActionSetID, ActionSetRefusal)
    /// The caller passed no recall source for this resolved patch: a caller error, not a project-data problem.
    case recallSourceUnavailable(PatchID)
    /// The caller passed no action-set source for this resolved set: a caller error, not a project-data problem.
    case actionSetSourceUnavailable(ActionSetID)

    /// `true` when the show can recover by relinking or editing project data. A structural activation review
    /// waits for the #62 activation path, and a missing recall or action-set source is a caller error that no
    /// project edit fixes, so those are not recoverable.
    var isRecoverable: Bool {
        switch self {
        case .requiresStructuralActivationReview, .recallSourceUnavailable, .actionSetSourceUnavailable: false
        case .unresolvedLink, .patchRecallRefused, .actionSetRefused: true
        }
    }
}

/// One item of a plan.
enum ShowTransitionStep<Planned: Equatable & Sendable>: Equatable, Sendable {
    /// The target stop links nothing for this item.
    case unlinked
    case planned(Planned)
    case blocked(ShowTransitionBlock)

    var planned: Planned? {
        if case let .planned(value) = self { return value }
        return nil
    }

    var block: ShowTransitionBlock? {
        if case let .blocked(block) = self { return block }
        return nil
    }
}

/// A reviewable transition between two stops. Values only: holding or comparing a plan has no effect.
struct ShowTransitionPlan: Equatable, Sendable {
    /// `nil` when the cursor had no stop before this move. Names the stop only: the patch recalled from is the
    /// planner's `active` input, not this stop's link.
    let from: ShowStopReference?
    let to: ShowStopReference
    /// The variation recall within the loaded patch, when the target links that same patch.
    let patch: ShowTransitionStep<PatchRecallPlan>
    /// The target's action set to arm, with its readiness at planning time. Arming never fires it, and a set that
    /// is not ready is still planned: its report says which members are not ready and why.
    let actionSet: ShowTransitionStep<ActionSetReadinessReport>
    /// The target's chart, when available.
    let chart: ShowTransitionStep<ChartReference>

    /// Every block, in the fixed order patch, action set, chart.
    var blocks: [ShowTransitionBlock] { [patch.block, actionSet.block, chart.block].compactMap(\.self) }
    var isClear: Bool { blocks.isEmpty }
}
