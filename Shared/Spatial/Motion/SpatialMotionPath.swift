//
//  SpatialMotionPath.swift
//  FluxKlang
//
//  A pure waypoint path in the neutral plane for one spatial source, evaluated at an integer sample frame (#116).
//  It moves no audio, knows no sample rate or time source and is not wired to any renderer.
//

// swiftlint:disable identifier_name
/// One waypoint: an integer sample frame and a position in the neutral plane. A plain carrier; `SpatialMotionPath.make`
/// validates it.
struct SpatialMotionWaypoint: Equatable, Sendable {
    let frame: Int64
    let x: Double
    let y: Double
}
// swiftlint:enable identifier_name

/// How a path is read after its last frame.
enum SpatialMotionMode: Equatable, Sendable {
    /// The path holds its last waypoint from the last frame onward.
    case once
    /// The path wraps: the last frame reads the first waypoint again. A path whose last point differs from its first
    /// jumps at the wrap.
    case loop
}

/// A validated path of 2...256 waypoints with strictly increasing frames in `0...maximumFrame`, joined by straight
/// segments. `point(at:)` is total over every `Int64` frame. Frames are the caller's sample frames; converting a
/// rate or a time is the consumer's job.
struct SpatialMotionPath: Equatable, Sendable {
    static let minimumWaypoints = 2
    static let maximumWaypoints = 256
    /// 2^53: every integer in `0...2^53` converts to `Double` exactly, and 2^53 + 1 does not.
    static let maximumFrame: Int64 = 9_007_199_254_740_992
    static let maximumSamples = 4096

    let source: SpatialSourceID
    let mode: SpatialMotionMode
    let waypoints: [SpatialMotionWaypoint]

    private init(source: SpatialSourceID, mode: SpatialMotionMode, waypoints: [SpatialMotionWaypoint]) {
        self.source = source
        self.mode = mode
        self.waypoints = waypoints
    }

    /// Builds a path, keeping the waypoints in the caller's order and bits. The checks run in this order: more than
    /// 256 waypoints, fewer than 2, then for each waypoint in index order (all of waypoint i before waypoint i + 1) its
    /// frame range, finite coordinates, coordinate range and, from index 1, a frame greater than the previous one. A
    /// coordinate outside -1...1 is refused, never clamped.
    static func make(
        source: SpatialSourceID,
        mode: SpatialMotionMode,
        waypoints: [SpatialMotionWaypoint]
    ) throws(SpatialMotionRefusal) -> Self {
        let count = waypoints.count
        guard count <= maximumWaypoints else { throw .tooManyWaypoints(count) }
        guard count >= minimumWaypoints else { throw .tooFewWaypoints(count) }
        var previousFrame: Int64?
        for index in 0..<count {
            let waypoint = waypoints[index]
            try validate(waypoint, index: index, previousFrame: previousFrame)
            previousFrame = waypoint.frame
        }
        return Self(source: source, mode: mode, waypoints: waypoints)
    }

    private static func validate(
        _ waypoint: SpatialMotionWaypoint,
        index: Int,
        previousFrame: Int64?
    ) throws(SpatialMotionRefusal) {
        guard (0...maximumFrame).contains(waypoint.frame) else { throw .frameOutOfRange(index: index) }
        guard waypoint.x.isFinite, waypoint.y.isFinite else { throw .nonFiniteCoordinate(index: index) }
        guard NeutralPoint.range.contains(waypoint.x), NeutralPoint.range.contains(waypoint.y) else {
            throw .coordinateOutOfRange(index: index)
        }
        if let previousFrame, waypoint.frame <= previousFrame { throw .frameNotIncreasing(index: index) }
    }

    /// The position at a sample frame. A frame at or before the first waypoint's frame gives the first waypoint in both
    /// modes. In `once` a frame at or after the last waypoint's frame gives the last waypoint. In `loop` a later frame
    /// wraps into `first ..< last` (the last frame reads the first waypoint). A frame on a waypoint belongs to the
    /// segment that starts there. Each axis is `a + (b - a) * t` with `t` one division of exact integer offsets. A zero
    /// axis is returned as +0.0.
    func point(at frame: Int64) -> NeutralPoint {
        let first = waypoints[0]
        let last = waypoints[waypoints.count - 1]
        if frame <= first.frame { return Self.held(first) }
        if mode == .once, frame >= last.frame { return Self.held(last) }
        let duration = last.frame - first.frame
        let local = mode == .loop ? first.frame + (frame - first.frame) % duration : frame
        for index in 1..<waypoints.count where local < waypoints[index].frame {
            return Self.interpolated(waypoints[index - 1], waypoints[index], at: local)
        }
        return Self.held(last)
    }

    private static func held(_ waypoint: SpatialMotionWaypoint) -> NeutralPoint {
        NeutralPoint(clampingFinite: unsignedZero(waypoint.x), y: unsignedZero(waypoint.y))
    }

    private static func interpolated(
        _ from: SpatialMotionWaypoint,
        _ to: SpatialMotionWaypoint,
        at local: Int64
    ) -> NeutralPoint {
        let offset = Double(local - from.frame)
        let length = Double(to.frame - from.frame)
        let fraction = offset / length
        let horizontal = from.x + (to.x - from.x) * fraction
        let vertical = from.y + (to.y - from.y) * fraction
        return NeutralPoint(clampingFinite: unsignedZero(horizontal), y: unsignedZero(vertical))
    }

    private static func unsignedZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }
}
