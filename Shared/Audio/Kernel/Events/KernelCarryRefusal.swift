// #364 E5c kernel cycle component: why a carry plan was refused. Reference model; not RT-certified.

/// Why `KernelCarryRetiming.plan` refused. Checked in this order, so a plan with several defects reports the first:
/// `blockCapacityOutOfRange`, `negativeFrame`, `invalidRamp`, `frameOverflow`. Production re-admission
/// (`KernelCarryReadmission`) does not call that planner; it reports only `frameOverflow`.
/// Reference model; not RT-certified.
enum KernelCarryRefusal: Error, Equatable, Sendable {
    /// The replacement's block capacity is outside `1...KernelCycle.maximumBlockCapacity`.
    case blockCapacityOutOfRange(Int)
    /// The replacement's first frame is negative.
    case negativeFrame(Int64)
    /// A recorded `rampTo` has a negative duration or a non-finite value; reports the lowest such parameter.
    case invalidRamp(parameter: UInt32)
    /// The completion frame of a surviving `rampTo` (its frame, re-timed when planned by `KernelCarryRetiming`, plus
    /// its duration) is not representable in `Int64`. No other frame arithmetic is checked.
    case frameOverflow
}
