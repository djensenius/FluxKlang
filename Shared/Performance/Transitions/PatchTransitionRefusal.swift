//
//  PatchTransitionRefusal.swift
//  FluxKlang
//
//  Typed refusals of a patch transition. A refused prepare builds no plan and leaves the tracker unchanged.
//

/// Why a transition, budget or target table is refused. Refusals take precedence over pressure: an input that is
/// both invalid and over budget is refused, never deferred. A prepare stops at the first refusal in this order:
/// 1. the recall plan itself: `.changesWithoutVariationChange`, `.tooManyParameterChanges`, then per change in order
///    `.unsorted`, `.nonFinite`, `.unitMismatch`, `.unchanged`;
/// 2. merging with the tracker's state: `.discontinuousVariation` against the recalled patch's recorded variation,
///    then `.discontinuous` per change in order, then the merged capacity `.tooManyMergedChanges`;
/// 3. `.unboundRoute` (lowest first), `.recallPatchNotRouted`, then (tracker only) `.untrackedRoute`.
enum PatchTransitionRefusal: Error, Hashable, Sendable {
    /// A budget outside `PatchTransitionBudget.retainedRouteBounds` or `tailSlotBounds`.
    case invalidBudget(retainedRoutes: Int, tailSlots: Int)
    /// More route bindings than `PatchRouteTargets.maximumBindings`.
    case tooManyBindings(count: Int, maximum: Int)
    /// The same route is bound twice.
    case duplicateBinding(MIDIRouteID)
    /// A route of the old or new routing, or a route the ledger still sounds on, has no patch target.
    case unboundRoute(MIDIRouteID)
    /// The recall plan is not one `PatchRecallPlanner` could have produced, or does not continue a deferred change.
    case invalidRecallPlan(PatchRecallDefect)
    /// The recall plan has more changes than `PatchTransitionPlan.maximumParameterChanges`, which no plan
    /// `PatchRecallPlanner` produces can have.
    case tooManyParameterChanges(count: Int, maximum: Int)
    /// A capacity refusal, not a defect of the recall plan: the patch's changes merged with those still deferred
    /// would exceed `PatchTransitionPlan.maximumParameterChanges`.
    case tooManyMergedChanges(PatchID, count: Int, maximum: Int)
    /// No route of the new routing plays the recalled patch, so its changes would apply nowhere.
    case recallPatchNotRouted(PatchID)
    /// The ledger sounds on a route the tracker neither routes to nor retains: the ledger was not routed with the
    /// tracker's routing.
    case untrackedRoute(MIDIRouteID)
}

/// What is wrong with a recall plan.
enum PatchRecallDefect: Hashable, Sendable {
    /// Changes are not strictly ascending by parameter (out of order or duplicated) at this parameter.
    case unsorted(ParameterID)
    /// A change whose `from` equals its `to`.
    case unchanged(ParameterID)
    /// A change whose `from` and `to` units differ.
    case unitMismatch(ParameterID)
    /// A change with a non-finite value.
    case nonFinite(ParameterID)
    /// `from` and `to` name the same variation (or both the baseline) but the plan has changes.
    case changesWithoutVariationChange
    /// A change whose `from` is not the `to` of the change still deferred for the same patch and parameter.
    case discontinuous(ParameterID)
    /// The recall's `from` is not `expected`, the variation the tracker records for the patch while retained routes
    /// play it (nil: the baseline). Refused even when the recall changes none of the deferred parameters, and even
    /// once every deferred change has cancelled (A→B→C).
    case discontinuousVariation(PatchID, expected: PatchVariationID?)
}
