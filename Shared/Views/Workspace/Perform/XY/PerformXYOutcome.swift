/// Which side of its range an axis value was clamped from.
enum PerformXYClamp: Equatable, Sendable {
    case belowRange
    case aboveRange
}

/// A value inside an axis range and the clamp that produced it, nil when the input was already inside.
struct PerformXYClampedValue: Equatable, Sendable {
    let value: Int
    let clamp: PerformXYClamp?
}

/// A pad coordinate pair. Pointer input may lie anywhere; a pad position lies inside its ranges.
struct PerformXYPoint: Equatable, Sendable {
    let x: Int // swiftlint:disable:this identifier_name
    let y: Int // swiftlint:disable:this identifier_name
}

/// A pad whose input was applied: the pad after the input and the clamp each axis needed.
struct PerformXYMove: Equatable, Sendable {
    let pad: PerformXYPad
    let xClamp: PerformXYClamp?
    let yClamp: PerformXYClamp?
}

/// An input held for pickup: the clamped position it asked for and the position that stays.
struct PerformXYHold: Equatable, Sendable {
    let requested: PerformXYPoint
    let current: PerformXYPoint
}

/// The result of a valid input: applied, or held with no new pad.
enum PerformXYOutcome: Equatable, Sendable {
    case moved(PerformXYMove)
    case held(PerformXYHold)
}
