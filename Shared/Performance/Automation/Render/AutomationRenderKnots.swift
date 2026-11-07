//
//  AutomationRenderKnots.swift
//  FluxKlang
//
//  The points the rendered trajectory passes through (#108 T2), in order:
//  every breakpoint at `frame(atTicks:)` of its tick with its own value, and,
//  inside a linear or power segment, every tempo-map boundary and the loop end
//  at their mapped frames with the curve's value there, so a tempo change moves
//  ramp boundaries to exactly the mapped frames. A power segment adds at most
//  `AutomationPowerApproximation.maximumSubRamps - 1` interior knots, each on
//  the curve at an integer frame, so it renders as at most that many linear
//  sub-ramps (tempo and loop knots only split them further). Knots depend only
//  on the lane and the pass's clock, never on the block, so any split of a
//  window into blocks yields the same knots.
//

import Foundation

/// How a power segment is approximated by linear sub-ramps.
enum AutomationPowerApproximation {
    /// The most linear sub-ramps a power segment renders as (owner ruling Q-T2).
    static let maximumSubRamps = 8
    /// The largest deviation of the sub-ramps from the curve, as a fraction of the segment's value change, for
    /// knots at the ideal fractions below (the worst case over `AutomationInterpolation.exponentRange` is about
    /// 0.043, at exponent 0.125). Knots snap to integer frames, so at a frame the rendered value may also differ
    /// by the curve's largest one-frame change within that sub-ramp.
    static let errorBound = 0.05

    /// The segment fraction, in ticks, of interior knot `knot` (`1..<maximumSubRamps`). Knots gather where the
    /// curve bends most: near the start for exponents below 1, near the end above 1.
    static func fraction(_ knot: Int, exponent: Double) -> Double {
        let unit = Double(knot) / Double(maximumSubRamps)
        return exponent < 1 ? pow(unit, 1.5 / exponent) : 1 - pow(1 - unit, (exponent / 2).squareRoot())
    }
}

/// One point of the rendered trajectory.
struct AutomationKnot: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case breakpoint(Int)
        /// The `index`th knot strictly inside the segment that opens at breakpoint `segment`.
        case interior(segment: Int, index: Int)
    }

    let kind: Kind
    let frame: Int64
    /// The musical position; exact for breakpoint, tempo and loop knots.
    let ticks: Double
    let value: Double

    /// The breakpoint that opens the segment the piece leaving this knot belongs to.
    var segment: Int {
        switch kind {
        case .breakpoint(let index): index
        case .interior(let segment, _): segment
        }
    }
}

/// The knots of one lane through one pass's clock. Interior knots of the last segment asked for are cached.
struct AutomationKnotSource {
    let lane: AutomationLane
    let pass: AutomationRenderPass
    private var cached: (segment: Int, knots: [AutomationKnot])?

    init(lane: AutomationLane, pass: AutomationRenderPass) {
        self.lane = lane
        self.pass = pass
    }

    private var breakpoints: [AutomationBreakpoint] { lane.breakpoints }

    func breakpoint(_ index: Int) throws(AutomationRenderRefusal) -> AutomationKnot {
        let point = breakpoints[index]
        let frame = try AutomationRenderMath.frame(point.ticks, on: pass.clock)
        return AutomationKnot(kind: .breakpoint(index), frame: frame, ticks: Double(point.ticks), value: point.value)
    }

    /// Whether the piece leaving `knot` ramps (linear or power) rather than holds.
    func ramps(from knot: AutomationKnot) -> Bool {
        knot.segment + 1 < breakpoints.count && breakpoints[knot.segment].interpolation != .step
    }

    /// The knot after `knot`, or `nil` after the last breakpoint.
    mutating func next(after knot: AutomationKnot) throws(AutomationRenderRefusal) -> AutomationKnot? {
        let segment = knot.segment
        guard segment + 1 < breakpoints.count else { return nil }
        let inner = try interior(segment)
        switch knot.kind {
        case .breakpoint:
            if let first = inner.first { return first }
        case .interior(_, let index):
            if index + 1 < inner.count { return inner[index + 1] }
        }
        return try breakpoint(segment + 1)
    }

    /// The last knot before `frame` (`nil` if none) and the knot after it (`nil` for an empty lane).
    mutating func bracket(before frame: Int64) throws(AutomationRenderRefusal)
        -> (previous: AutomationKnot?, current: AutomationKnot?) {
        guard !breakpoints.isEmpty else { return (nil, nil) }
        var low = 0
        var high = breakpoints.count
        while low < high {
            let middle = (low + high) / 2
            if try AutomationRenderMath.frame(breakpoints[middle].ticks, on: pass.clock) < frame {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return (nil, try breakpoint(0)) }
        var previous = try breakpoint(low - 1)
        if low < breakpoints.count, let last = try interior(low - 1).last(where: { $0.frame < frame }) {
            previous = last
        }
        return (previous, try next(after: previous))
    }

    /// The knot a ramp from `position` heads for, when `position` lies inside a ramping piece; `nil` when the
    /// lane holds there (before the first breakpoint, after the last, or in a step segment).
    mutating func target(after position: Double) throws(AutomationRenderRefusal) -> AutomationKnot? {
        var low = 0
        var high = breakpoints.count
        while low < high {
            let middle = (low + high) / 2
            if Double(breakpoints[middle].ticks) <= position { low = middle + 1 } else { high = middle }
        }
        let segment = low - 1
        guard segment >= 0, segment + 1 < breakpoints.count,
              breakpoints[segment].interpolation != .step else { return nil }
        if let knot = try interior(segment).first(where: { $0.ticks > position }) { return knot }
        return try breakpoint(segment + 1)
    }

    /// The knots strictly inside segment `segment`, ordered by frame, then position.
    mutating func interior(_ segment: Int) throws(AutomationRenderRefusal) -> [AutomationKnot] {
        if let cached, cached.segment == segment { return cached.knots }
        let knots = try makeInterior(segment)
        cached = (segment, knots)
        return knots
    }

    private func makeInterior(_ segment: Int) throws(AutomationRenderRefusal) -> [AutomationKnot] {
        let start = breakpoints[segment]
        let end = breakpoints[segment + 1]
        guard start.interpolation != .step, start.ticks < end.ticks else { return [] }
        var ticks = pass.clock.map.segments.map(\.atTicks).filter { start.ticks < $0 && $0 < end.ticks }
        if let loopEnd = pass.loopEnd, start.ticks < loopEnd, loopEnd < end.ticks, !ticks.contains(loopEnd) {
            ticks.append(loopEnd)
            ticks.sort()
        }
        var points: [(frame: Int64, ticks: Double)] = []
        for tick in ticks {
            points.append((try AutomationRenderMath.frame(tick, on: pass.clock), Double(tick)))
        }
        if case .power(let exponent) = start.interpolation {
            let taken = Set(points.map(\.frame))
            for frame in try powerFrames(start, end, exponent: exponent) where !taken.contains(frame) {
                points.append((frame, pass.exactTicks(atFrame: frame).position))
            }
        }
        points.sort { ($0.frame, $0.ticks) < ($1.frame, $1.ticks) }
        var knots: [AutomationKnot] = []
        for (index, point) in points.enumerated() {
            knots.append(AutomationKnot(kind: .interior(segment: segment, index: index), frame: point.frame,
                                        ticks: point.ticks, value: try value(point.ticks)))
        }
        return knots
    }

    /// The frames of a power segment's interior knots: for each ideal fraction's tick, the frame whose exact
    /// position is nearest it (estimated between the frames of its neighbouring whole ticks, then settled with
    /// `exactTicks(atFrame:)`), kept strictly increasing and strictly inside the segment.
    private func powerFrames(_ start: AutomationBreakpoint, _ end: AutomationBreakpoint,
                             exponent: Double) throws(AutomationRenderRefusal) -> [Int64] {
        let first = try AutomationRenderMath.frame(start.ticks, on: pass.clock)
        let last = try AutomationRenderMath.frame(end.ticks, on: pass.clock)
        let span = Double(end.ticks - start.ticks)
        var frames: [Int64] = []
        var previous = first
        for knot in 1..<AutomationPowerApproximation.maximumSubRamps {
            let ideal = Double(start.ticks) + span * AutomationPowerApproximation.fraction(knot, exponent: exponent)
            let lower = min(max(Int64(ideal.rounded(.down)), start.ticks), end.ticks - 1)
            let low = try AutomationRenderMath.frame(lower, on: pass.clock)
            let high = try AutomationRenderMath.frame(lower + 1, on: pass.clock)
            let mapped = Double(low) + (ideal - Double(lower)) * Double(high - low)
            var nearest = try AutomationRenderMath.roundedFrame(mapped)
            let distance = { (frame: Int64) in abs(pass.exactTicks(atFrame: frame).position - ideal) }
            while nearest > first, distance(nearest - 1) < distance(nearest) { nearest -= 1 }
            while nearest < last, distance(nearest + 1) < distance(nearest) { nearest += 1 }
            let frame = max(nearest, previous + 1)
            guard frame < last else { break }
            frames.append(frame)
            previous = frame
        }
        return frames
    }

    private func value(_ position: Double) throws(AutomationRenderRefusal) -> Double {
        do {
            return try lane.value(at: position) ?? 0
        } catch {
            throw .automation(error)
        }
    }
}
