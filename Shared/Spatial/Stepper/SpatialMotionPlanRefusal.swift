//
//  SpatialMotionPlanRefusal.swift
//  FluxKlang
//
//  Why a spatial motion plan run is refused (#116). A refusal returns no plan and no partial list.
//

/// A refusal of `SpatialMotionPlanStepper.plans` or `SpatialMotionPlanStepper.plan`. The checks of `plans` run in this
/// order, each one before any work of a later one:
/// 1. `planCountOutOfRange`: a plan count outside `0...SpatialMotionPlanStepper.maximumPlans`.
/// 2. `motion(.stepNotPositive)`: a step below one frame (also when the count is 0).
/// 3. `render(.tooManySources)`: more placements than `SpatialRenderer.maximumSources`.
/// 4. `sourceNotPlaced`: no placement carries the path's source id.
/// 5. A count of 0 returns an empty array.
/// 6. `tooManyCells`: `count * rows * speakers` above `SpatialMotionPlanStepper.maximumCells`.
/// 7. `motion(.frameOverflow)`: the span or the last frame overflows `Int64`.
/// 8. `render`: the first step whose placement rebuild or `SpatialRenderer.plan` throws.
/// `plan` runs checks 3, 4 and 8.
enum SpatialMotionPlanRefusal: Error, Equatable, Sendable {
    /// A plan count outside `0...SpatialMotionPlanStepper.maximumPlans`; carries the count.
    case planCountOutOfRange(Int)
    /// The path refused the frames. Only `stepNotPositive` and `frameOverflow` occur: the sample count cap of the path
    /// is above the plan cap, which is checked first.
    case motion(SpatialMotionRefusal)
    /// The request has no placement for the path's source; carries that source.
    case sourceNotPlaced(SpatialSourceID)
    /// The plans of one call would hold more gains than `SpatialMotionPlanStepper.maximumCells`; carries the total.
    case tooManyCells(Int)
    /// The renderer (or the placement rebuild, as `.layout`) refused the request.
    case render(SpatialRenderError)
}
