/// Every numeric bound of the WING compatibility lease, in one place.
///
/// The limits are counts, not seconds: the tick unit is chosen by the adapter that feeds the lease, because the lease
/// itself never reads a clock.
enum WingLeaseLimits {
    /// Largest valid tick (the smallest is 0).
    static let maximumTick = 1_000_000_000_000
    /// Largest grant duration in ticks (the smallest is `minimumCount`).
    static let maximumDurationTicks = 3_600_000
    /// Largest number of settings one grant may write.
    static let maximumSettingBudget = 1_024
    /// Largest number of settings in one write or restore-write request.
    static let maximumSettingsPerRequest = 256
    /// Smallest valid duration, budget, request size and planned count.
    static let minimumCount = 1
}
