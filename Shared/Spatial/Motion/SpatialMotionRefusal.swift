//
//  SpatialMotionRefusal.swift
//  FluxKlang
//
//  Why a spatial motion path or a run of samples is refused (#116). A refusal returns no value; the checks run in the
//  order the cases are listed below.
//

/// A refusal of `SpatialMotionPath.make` or `SpatialMotionPath.samples`. An `index` is the position of the offending
/// waypoint in the caller's array.
enum SpatialMotionRefusal: Error, Equatable, Sendable {
    /// More than `SpatialMotionPath.maximumWaypoints` waypoints; carries the count.
    case tooManyWaypoints(Int)
    /// Fewer than `SpatialMotionPath.minimumWaypoints` waypoints; carries the count.
    case tooFewWaypoints(Int)
    /// A frame outside `0...SpatialMotionPath.maximumFrame`.
    case frameOutOfRange(index: Int)
    /// A coordinate that is NaN or infinite.
    case nonFiniteCoordinate(index: Int)
    /// A finite coordinate outside the neutral plane; it is refused, never clamped.
    case coordinateOutOfRange(index: Int)
    /// A frame that is not greater than the previous waypoint's frame.
    case frameNotIncreasing(index: Int)
    /// A sample count outside `0...SpatialMotionPath.maximumSamples`; carries the count.
    case sampleCountOutOfRange(Int)
    /// A step below one frame; carries the step.
    case stepNotPositive(Int64)
    /// The span `(count - 1) * stepFrames`, or the last frame `firstFrame + span`, overflows `Int64`.
    case frameOverflow
}
