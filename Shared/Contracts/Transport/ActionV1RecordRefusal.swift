//
//  ActionV1RecordRefusal.swift
//  FluxKlang
//
//  Why a declaration cannot become one entry of the contract v1 `actions` header (#107 ACT1). In memory only;
//  nothing is clamped, remapped or serialized in its place.
//

/// The first offence `ActionV1Record.make` finds, in this order: the action ID, the policy's extension fields, the
/// `quantize` grid, the `quantize` musical ticks, a missing audio `prefetch`, a `nextBoundary` without a grid
/// `quantize`, then a policy grid that `quantize` does not state.
enum ActionV1RecordRefusal: Error, Hashable, Sendable {
    /// The action ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidActionID(ActionID)
    /// The policy carries `unknownFields` or `extensions`; the schema's `additionalProperties` is false.
    case extensionFields
    /// `quantize` is `.grid(ticks:)` with ticks below 1.
    case invalidGrid(Int64)
    /// `quantize` is `.musical(atTicks:)` with ticks below 0.
    case negativeMusicalTicks(Int64)
    /// An `audio` action with no `prefetch`; the checker requires one.
    case audioWithoutPrefetch
    /// The late policy is `nextBoundary` and `quantize` is not a grid; the checker needs a `gridTicks`.
    case nextBoundaryWithoutGrid
    /// The policy's grid (its `gridTicks`, else the one inside `nextBoundary`) is not what `quantize` states.
    /// The trace has one place for a grid, so the two must agree. Carries the policy's grid and `quantize`.
    case policyGridMismatch(policy: Int64, quantize: TriggerTarget)
}
