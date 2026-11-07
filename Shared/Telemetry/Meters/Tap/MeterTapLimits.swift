// #66 MET1 meter tap: the only place for the tap's numeric bounds. Reference model; not RT-certified.

/// Numeric bounds of the producer-side meter tap. Uninhabited: it only namespaces constants.
enum MeterTapLimits {
    /// Largest channel count of one `MeterTapAccumulator` (inclusive). Equals `MeterSource.maximumChannels` and
    /// fits `KernelLimits.maximumTelemetrySlots`; the tap does not depend on `MeterSource`.
    static let maximumChannels: Int = 64

    /// Lowest level the tap reports for a non-silent peak, in dBFS. It is the lowest value
    /// `MeterBallistics.allowedFloorDBFS` permits, so a display floor never sits below the tap's floor.
    static let floorDBFS: Double = -200
}
