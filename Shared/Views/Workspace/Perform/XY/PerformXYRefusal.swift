/// One of the two pad axes.
enum PerformXYAxis: Equatable, Sendable {
    case x // swiftlint:disable:this identifier_name
    case y // swiftlint:disable:this identifier_name
}

/// Why a pad value or an operation on it was refused. Range refusals carry no axis.
enum PerformXYRefusal: Error, Equatable, Sendable {
    /// A range bound lies beyond the magnitude limit.
    case boundOutOfLimit
    /// The lower bound of a range is above its upper bound.
    case rangeInverted
    /// The capture radius is outside the allowed span.
    case captureRadiusOutOfLimit(Int)
    /// The position lies outside the range of the named axis.
    case positionOutsideRange(PerformXYAxis)
    /// An entry named neither axis.
    case noAxisGiven
    /// An adjustment asked for zero steps.
    case stepIsZero
}
