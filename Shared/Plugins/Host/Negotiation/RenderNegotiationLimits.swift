/// Every numeric bound of the host-neutral render negotiation, in one place.
///
/// These are host policy bounds, not Apple limits: they are conservative choices that are UNVERIFIED against the
/// AUv2/AUv3 documentation. Sample rates are integer Hz (fractional or non-integer rates are unsupported). The scratch
/// requirement derived from them excludes alignment padding and plugin-internal allocations, so it is a necessary,
/// not a sufficient, bound.
enum RenderNegotiationLimits {
    static let minimumSampleRateHz = 8_000
    static let maximumSampleRateHz = 384_000
    static let maximumFrames = 16_384
    static let busesPerDirection = PluginCatalogLimits.busesPerDirection
    static let channelsPerBus = PluginCatalogLimits.channelsPerBus
    /// Upper bound of the plugin-side render buffers of one maximum block (the scratch arena capacity).
    static let scratchBytes = ScratchArena.maximumByteCapacity
    /// Reprepare attempts of `ReprepareBudget.standard`.
    static let reprepareAttemptsStandard = 3
    /// Largest accepted `ReprepareBudget.maximumAttempts`.
    static let reprepareAttemptsCeiling = 8
}
