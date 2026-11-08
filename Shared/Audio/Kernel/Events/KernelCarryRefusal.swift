// #364 E5c kernel cycle component: why a carry plan was refused. Reference model; not RT-certified.

/// Why `KernelCarryRetiming.plan` refused. Checked in this order, so a plan with several defects reports the first:
/// `blockCapacityOutOfRange`, `negativeFrame`, `invalidRamp`, `frameOverflow`.
/// Reference model; not RT-certified.
enum KernelCarryRefusal: Error, Equatable, Sendable {
    /// The replacement's block capacity is outside `1...KernelCycle.maximumBlockCapacity`.
    case blockCapacityOutOfRange(Int)
    /// The replacement's first frame is negative.
    case negativeFrame(Int64)
    /// A recorded `rampTo` has a negative duration or a non-finite value; reports the lowest such parameter.
    case invalidRamp(parameter: UInt32)
    /// The replacement block's end, or a surviving ramp's completion frame, is not representable in `Int64`.
    case frameOverflow
}
