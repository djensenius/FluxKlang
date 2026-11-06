//
//  PatchTransitionRefusal.swift
//  FluxKlang
//
//  Typed refusals of a patch transition. A refused prepare builds no plan and leaves the tracker unchanged.
//

/// Why a transition, budget or target table is refused. Refusals take precedence over pressure: an input that is
/// both invalid and over budget is refused, never deferred. Checks stop at the first refusal in this order: the recall
/// plan, the parameter change count, unbound routes (ascending), the recalled patch's routing, then untracked routes.
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
    /// The recall plan's changes, merged with the changes still deferred, exceed
    /// `PatchTransitionPlan.maximumParameterChanges`.
    case tooManyParameterChanges(count: Int, maximum: Int)
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
}
