/// The pickup state one pad shares across both axes: engaged applies input; waiting holds input until a pointer comes
/// within the capture radius, or until `takingOver()`.
enum PerformXYPickup: Equatable, Sendable {
    case engaged
    case waiting
}

/// The integer steps one axis can hold, from `lower` to `upper` inclusive. Equal bounds make a one-step axis.
struct PerformXYAxisRange: Equatable, Sendable {
    /// The largest bound magnitude a range accepts.
    static let maximumMagnitude = 1_000_000

    private let storedLower: Int
    private let storedUpper: Int

    var lower: Int { storedLower }
    var upper: Int { storedUpper }

    private init(lower: Int, upper: Int) {
        storedLower = lower
        storedUpper = upper
    }

    /// Refuses a bound beyond the magnitude limit first, then a lower bound above the upper bound.
    static func make(lower: Int, upper: Int) throws(PerformXYRefusal) -> PerformXYAxisRange {
        guard isWithinLimit(lower), isWithinLimit(upper) else { throw .boundOutOfLimit }
        guard lower <= upper else { throw .rangeInverted }
        return PerformXYAxisRange(lower: lower, upper: upper)
    }

    private static func isWithinLimit(_ bound: Int) -> Bool {
        bound >= -maximumMagnitude && bound <= maximumMagnitude
    }

    func contains(_ value: Int) -> Bool {
        value >= storedLower && value <= storedUpper
    }

    /// The nearest value inside the range and the side it was clamped from; a value on a bound is inside.
    func clamped(_ value: Int) -> PerformXYClampedValue {
        if value < storedLower {
            return PerformXYClampedValue(value: storedLower, clamp: .belowRange)
        }
        if value > storedUpper {
            return PerformXYClampedValue(value: storedUpper, clamp: .aboveRange)
        }
        return PerformXYClampedValue(value: value, clamp: nil)
    }
}

/// Two axis ranges, one position inside them and one pickup state shared by both axes.
/// Operations return new values; a held input returns no pad.
struct PerformXYPad: Equatable, Sendable {
    /// The largest capture radius a pad accepts.
    static let maximumCaptureRadius = 1_000_000

    private let storedXRange: PerformXYAxisRange
    private let storedYRange: PerformXYAxisRange
    private let storedPosition: PerformXYPoint
    private let storedPickup: PerformXYPickup
    private let storedCaptureRadius: Int

    var xRange: PerformXYAxisRange { storedXRange }
    var yRange: PerformXYAxisRange { storedYRange }
    var position: PerformXYPoint { storedPosition }
    var pickup: PerformXYPickup { storedPickup }
    var captureRadius: Int { storedCaptureRadius }

    private init(
        xRange: PerformXYAxisRange,
        yRange: PerformXYAxisRange,
        position: PerformXYPoint,
        pickup: PerformXYPickup,
        captureRadius: Int
    ) {
        storedXRange = xRange
        storedYRange = yRange
        storedPosition = position
        storedPickup = pickup
        storedCaptureRadius = captureRadius
    }

    /// Refuses a capture radius outside `0...maximumCaptureRadius` first, then a position outside the x range,
    /// then one outside the y range. The position is checked, not clamped.
    static func make(
        xRange: PerformXYAxisRange,
        yRange: PerformXYAxisRange,
        position: PerformXYPoint,
        pickup: PerformXYPickup,
        captureRadius: Int
    ) throws(PerformXYRefusal) -> PerformXYPad {
        guard captureRadius >= 0, captureRadius <= maximumCaptureRadius else {
            throw .captureRadiusOutOfLimit(captureRadius)
        }
        guard xRange.contains(position.x) else { throw .positionOutsideRange(.x) }
        guard yRange.contains(position.y) else { throw .positionOutsideRange(.y) }
        return PerformXYPad(
            xRange: xRange, yRange: yRange, position: position, pickup: pickup, captureRadius: captureRadius
        )
    }

    private func replacing(position: PerformXYPoint, pickup: PerformXYPickup) -> PerformXYPad {
        PerformXYPad(
            xRange: storedXRange, yRange: storedYRange, position: position, pickup: pickup,
            captureRadius: storedCaptureRadius
        )
    }

    /// A pointer move. The pointer is clamped into the ranges, then one decision covers both axes: an engaged pad
    /// applies it; a waiting pad applies it when both axis distances are within the capture radius, and
    /// then engages, otherwise it holds the input.
    func pointer(_ point: PerformXYPoint) -> PerformXYOutcome {
        let xResult = storedXRange.clamped(point.x)
        let yResult = storedYRange.clamped(point.y)
        let target = PerformXYPoint(x: xResult.value, y: yResult.value)
        if storedPickup == .waiting, !isWithinCaptureRadius(target) {
            return .held(PerformXYHold(requested: target, current: storedPosition))
        }
        let moved = replacing(position: target, pickup: .engaged)
        return .moved(PerformXYMove(pad: moved, xClamp: xResult.clamp, yClamp: yResult.clamp))
    }

    private func isWithinCaptureRadius(_ target: PerformXYPoint) -> Bool {
        let distanceX = abs(target.x - storedPosition.x)
        let distanceY = abs(target.y - storedPosition.y)
        return distanceX <= storedCaptureRadius && distanceY <= storedCaptureRadius
    }

    /// Typed entry for one or both axes. Naming neither axis is refused before the pickup state is consulted.
    /// A given value is clamped; an axis left nil keeps its position and reports no clamp.
    func entering(
        x: Int?, y: Int? // swiftlint:disable:this identifier_name
    ) throws(PerformXYRefusal) -> PerformXYOutcome {
        if x == nil, y == nil { throw .noAxisGiven }
        let xResult = x.map { storedXRange.clamped($0) }
        let yResult = y.map { storedYRange.clamped($0) }
        let target = PerformXYPoint(x: xResult?.value ?? storedPosition.x, y: yResult?.value ?? storedPosition.y)
        return resolve(target, xClamp: xResult?.clamp, yClamp: yResult?.clamp)
    }

    /// Moves one axis by a signed step count, clamped into its range, when the pad is engaged; a waiting pad
    /// holds the clamped target. Zero steps are refused before the pickup state is consulted. The other axis keeps
    /// its position.
    func adjusting(_ axis: PerformXYAxis, by steps: Int) throws(PerformXYRefusal) -> PerformXYOutcome {
        if steps == 0 { throw .stepIsZero }
        switch axis {
        case .x:
            let result = storedXRange.clamped(Self.shifted(storedPosition.x, by: steps))
            let target = PerformXYPoint(x: result.value, y: storedPosition.y)
            return resolve(target, xClamp: result.clamp, yClamp: nil)
        case .y:
            let result = storedYRange.clamped(Self.shifted(storedPosition.y, by: steps))
            let target = PerformXYPoint(x: storedPosition.x, y: result.value)
            return resolve(target, xClamp: nil, yClamp: result.clamp)
        }
    }

    private static func shifted(_ value: Int, by steps: Int) -> Int {
        Int(clamping: Int128(value) + Int128(steps))
    }

    private func resolve(
        _ target: PerformXYPoint, xClamp: PerformXYClamp?, yClamp: PerformXYClamp?
    ) -> PerformXYOutcome {
        if storedPickup == .waiting {
            return .held(PerformXYHold(requested: target, current: storedPosition))
        }
        let moved = replacing(position: target, pickup: storedPickup)
        return .moved(PerformXYMove(pad: moved, xClamp: xClamp, yClamp: yClamp))
    }

    /// An explicit take-over: the pad engages and keeps its position.
    func takingOver() -> PerformXYPad {
        replacing(position: storedPosition, pickup: .engaged)
    }

    /// The host moved the value: the position becomes the clamped point and the pad waits for the next catch.
    func hostMoved(to point: PerformXYPoint) -> PerformXYPad {
        let target = PerformXYPoint(x: storedXRange.clamped(point.x).value, y: storedYRange.clamped(point.y).value)
        return replacing(position: target, pickup: .waiting)
    }
}
