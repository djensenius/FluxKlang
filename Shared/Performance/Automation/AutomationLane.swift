import Foundation

/// How the curve runs from one breakpoint to the next. The last breakpoint's interpolation is unused.
enum AutomationInterpolation: Hashable, Sendable {
    /// Holds this breakpoint's value up to the next breakpoint, which then applies at once.
    case step
    case linear
    /// Moves from the start value toward the end value by the segment fraction `f` raised to
    /// `exponent`: between the two values, monotonic, exact at both ends. Exponents above 1 start
    /// slowly; below 1 start quickly.
    case power(Double)

    static let exponentRange: ClosedRange<Double> = 0.125...8
}

/// One point of a lane, keyed by an absolute musical position in ticks
/// (`MusicalTime.ticksPerQuarter` per quarter note), so the curve is independent of sample rate,
/// render block size and tempo. `interpolation` shapes the segment that starts here.
struct AutomationBreakpoint: Hashable, Sendable {
    let ticks: Int64
    let value: Double
    let interpolation: AutomationInterpolation

    init(ticks: Int64, value: Double, interpolation: AutomationInterpolation = .linear) {
        self.ticks = ticks
        self.value = value
        self.interpolation = interpolation
    }
}

/// A bounded, validated automation curve for one live parameter. Values are in the parameter's
/// unit and are clamped into its writable range (the descriptor's bounds, the upper bound lowered to
/// its ceiling, narrowed to whole steps for a stepped parameter) when the lane is built. Breakpoints
/// are given in non-decreasing tick order; two may share a tick to describe a discontinuity, whose
/// later value applies from that tick on.
///
/// Evaluation is a pure function of the position: before the first breakpoint the lane holds the
/// first value, after the last it holds the last value, an empty lane has no value.
struct AutomationLane: Hashable, Sendable {
    static let maximumBreakpoints = 4096
    /// Keeps every tick exactly representable as a `Double` position.
    static let maximumTicks: Int64 = 1 << 52

    let parameter: ParameterID
    let unit: ParameterUnit
    let range: ClosedRange<Double>
    let isStepped: Bool
    let breakpoints: [AutomationBreakpoint]

    init(descriptor: ParameterDescriptor, breakpoints: [AutomationBreakpoint]) throws(AutomationRefusal) {
        guard descriptor.controlClass == .live else { throw .unautomatableClass(descriptor.controlClass) }
        guard breakpoints.count <= Self.maximumBreakpoints else { throw .tooManyBreakpoints(breakpoints.count) }
        let stepped = descriptor.curve == .stepped
        let ceiling = descriptor.ceiling ?? descriptor.upper
        // A stepped parameter's bounds may fall between steps; only the steps inside them are writable.
        let lower = stepped ? descriptor.lower.rounded(.up) : descriptor.lower
        let upper = stepped ? ceiling.rounded(.down) : ceiling
        guard lower <= upper else { throw .noWritableStep(lower: descriptor.lower, upper: ceiling) }
        let range = lower...upper
        var admitted: [AutomationBreakpoint] = []
        admitted.reserveCapacity(breakpoints.count)
        for (index, point) in breakpoints.enumerated() {
            guard (0...Self.maximumTicks).contains(point.ticks) else { throw .ticksOutOfRange(point.ticks) }
            if index > 0, point.ticks < breakpoints[index - 1].ticks { throw .unsorted(index: index) }
            if index > 1, point.ticks == breakpoints[index - 2].ticks { throw .tooManyAtTick(point.ticks) }
            try Self.validate(point.interpolation, stepped: stepped)
            let value = try Self.admit(point.value, to: range, stepped: stepped)
            admitted.append(.init(ticks: point.ticks, value: value, interpolation: point.interpolation))
        }
        parameter = descriptor.id
        unit = descriptor.unit
        self.range = range
        isStepped = stepped
        self.breakpoints = admitted
    }

    /// The curve's value at `ticks`, or `nil` for an empty lane.
    func value(at ticks: Double) throws(AutomationRefusal) -> Double? {
        guard ticks.isFinite else { throw .nonFinite }
        guard let first = breakpoints.first, let last = breakpoints.last else { return nil }
        let index = firstIndex(after: ticks)
        if index == 0 { return first.value }
        if index == breakpoints.count { return last.value }
        return Self.interpolate(from: breakpoints[index - 1], to: breakpoints[index], at: ticks)
    }

    /// The first breakpoint strictly after `ticks`, if any.
    func nextBreakpoint(after ticks: Double) throws(AutomationRefusal) -> Int64? {
        guard ticks.isFinite else { throw .nonFinite }
        let index = firstIndex(after: ticks)
        return index < breakpoints.count ? breakpoints[index].ticks : nil
    }

    /// Admits an external value (a gesture) under the lane's rules: finite, integral when stepped,
    /// then clamped into the writable range.
    func admit(_ value: Double) throws(AutomationRefusal) -> Double {
        try Self.admit(value, to: range, stepped: isStepped)
    }

    /// Whether the observable trajectory, the values `value(at:)` returns over `start...end`, equals
    /// `target` or passes it (including by a jump). Each segment is monotonic, so it is exact to sample
    /// the start, every breakpoint the trajectory shows, and the end; the result does not depend on
    /// how the interval was split into calls.
    ///
    /// A breakpoint followed by another at the same tick is shadowed: `value(at:)` never returns it at
    /// that tick. Its incoming segment is sampled at the last position before the tick instead, so a
    /// step into it holds the step's value and a linear approach counts only the values it attains,
    /// never the shadowed end itself.
    func reaches(_ target: Double, from start: Double, through end: Double) throws(AutomationRefusal) -> Bool {
        guard target.isFinite, end.isFinite else { throw .nonFinite }
        guard let first = try value(at: start) else { return false }
        let below = first < target
        func departs(_ value: Double) -> Bool { value == target || (value < target) != below }
        if departs(first) { return true }
        var index = firstIndex(after: start)
        while index < breakpoints.count, Double(breakpoints[index].ticks) <= end {
            let point = breakpoints[index]
            let shadowed = index + 1 < breakpoints.count && breakpoints[index + 1].ticks == point.ticks
            let shown = shadowed ? try value(at: Double(point.ticks).nextDown) ?? first : point.value
            if departs(shown) { return true }
            index += 1
        }
        return try departs(value(at: end) ?? first)
    }

    /// The number of breakpoints at or before `ticks`.
    private func firstIndex(after ticks: Double) -> Int {
        var low = 0
        var high = breakpoints.count
        while low < high {
            let middle = (low + high) / 2
            if Double(breakpoints[middle].ticks) <= ticks { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func interpolate(from start: AutomationBreakpoint, to end: AutomationBreakpoint,
                                    at ticks: Double) -> Double {
        let fraction = (ticks - Double(start.ticks)) / Double(end.ticks - start.ticks)
        let shaped: Double
        switch start.interpolation {
        case .step: return start.value
        case .linear: shaped = fraction
        case .power(let exponent): shaped = pow(fraction, exponent)
        }
        return blend(start.value, end.value, at: shaped)
    }

    /// The point `fraction` (clamped to `0...1`) of the way from `from` to `to`; 0 gives `from` and 1
    /// gives `to` exactly. The result never decreases (or, for `to < from`, never increases) as
    /// `fraction` grows, and always lies between the two ends, so a catch sees the same crossings
    /// however a segment is sampled.
    ///
    /// With both ends on the same side of zero, `to - from` cannot overflow and is one rounded
    /// constant, so `from + (to - from) * fraction` is a chain of correctly rounded operations, each
    /// monotonic in its varying operand. With ends of opposite signs `to - from` can overflow, but
    /// `from * (1 - fraction)` and `to * fraction` each move monotonically toward their own end and
    /// their exact sum lies between the ends, so the rounded sum does too and keeps the direction.
    /// Weighting both ends for same-sign values is not monotonic: between adjacent values, rounding
    /// can return the upper one early and the lower one later. Below a fraction of 1 the scaled
    /// difference never exceeds `to - from` in size, so neither form leaves the span; the final clamp
    /// is only a guard. A non-finite fraction, which no caller produces, fails closed to `from`.
    static func blend(_ from: Double, _ to: Double, at fraction: Double) -> Double {
        guard fraction.isFinite else { return from }
        let weight = min(max(fraction, 0), 1)
        if weight == 1 { return to }
        let sameSign = (from >= 0 && to >= 0) || (from <= 0 && to <= 0)
        let value = sameSign ? from + (to - from) * weight : from * (1 - weight) + to * weight
        return min(max(value, min(from, to)), max(from, to))
    }

    private static func validate(_ interpolation: AutomationInterpolation,
                                 stepped: Bool) throws(AutomationRefusal) {
        if case .power(let exponent) = interpolation, !AutomationInterpolation.exponentRange.contains(exponent) {
            throw .invalidExponent(exponent)
        }
        if stepped, interpolation != .step { throw .interpolationNotAllowed(interpolation) }
    }

    private static func admit(_ value: Double, to range: ClosedRange<Double>,
                              stepped: Bool) throws(AutomationRefusal) -> Double {
        guard value.isFinite else { throw .nonFinite }
        if stepped, value.rounded() != value { throw .notIntegral(value) }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
