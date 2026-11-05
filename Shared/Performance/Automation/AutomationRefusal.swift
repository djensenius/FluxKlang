import Foundation

/// Why an automation lane could not be built, or why an arbitration event was refused.
/// A refused event leaves the arbiter exactly as it was.
enum AutomationRefusal: Error, Hashable, Sendable {
    /// Only `.live` parameters may be automated; structural and hazardous ones are refused.
    case unautomatableClass(ControlClass)
    /// A breakpoint value, gesture value or timeline position is NaN or infinite.
    case nonFinite
    /// A breakpoint lies outside `0...AutomationLane.maximumTicks`.
    case ticksOutOfRange(Int64)
    /// Breakpoints must be given in non-decreasing tick order; they are never silently sorted.
    case unsorted(index: Int)
    /// More than two breakpoints share one tick (two describe a discontinuity; three are ambiguous).
    case tooManyAtTick(Int64)
    case tooManyBreakpoints(Int)
    /// A power curve's exponent lies outside `AutomationInterpolation.exponentRange`.
    case invalidExponent(Double)
    /// Stepped parameters only accept `.step` segments.
    case interpolationNotAllowed(AutomationInterpolation)
    /// Stepped parameters only accept integral values.
    case notIntegral(Double)
    /// A stepped parameter's writable range (bounds lowered to the ceiling) holds no integral step.
    /// Defensive: a validated descriptor's integral default always lies in that range.
    case noWritableStep(lower: Double, upper: Double)
    /// A glide must last `1...AutomationResume.maximumGlideTicks` ticks.
    case invalidGlide(Int64)
    /// An event's position precedes the arbiter's; only `relocate` may move backwards.
    case timeRegressed(from: Double, to: Double)
    case notTouched(ControlSourceID)
    case alreadyTouched(ControlSourceID)
    /// More than `ParameterArbiter.maximumTouches` sources are touching at once.
    case tooManyTouches
}
