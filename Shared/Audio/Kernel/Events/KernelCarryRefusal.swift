// #364 E5c kernel cycle component: why a carry plan was refused. Reference model; not RT-certified.

/// Why `KernelCarryReadmission` refused to plan a carry (`KernelCarryReadmissionReport.planRefusal`); nothing is
/// re-admitted then. Reference model; not RT-certified.
enum KernelCarryRefusal: Error, Equatable, Sendable {
    /// The completion frame of a surviving `rampTo` (its original frame plus its duration) is not representable in
    /// `Int64`. No other frame arithmetic is checked.
    case frameOverflow
}
