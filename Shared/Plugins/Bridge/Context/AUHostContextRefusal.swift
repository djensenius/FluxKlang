/// Why an AU host musical context was refused. Values carry numbers and capability axes only, never text.
///
/// `AUHostContext.make` reports the first failure in this order: `invalidBlock`, `blockExceedsNegotiated`,
/// `negotiationStale`, `rateMismatch`, `loopActive`, `negativeFrame`, then the position faults `ticksOverflow` and
/// `beforeMusicalOrigin`. `contextStale` comes from `AUHostContext.validate(against:)`.
enum AUHostContextRefusal: Error, Hashable, Sendable {
    /// The block holds fewer than one frame.
    case invalidBlock(Int)
    /// The block is larger than the negotiated maximum.
    case blockExceedsNegotiated(blockFrames: Int, maximumFrames: Int)
    /// The negotiation was made at another `resources` or `sampleRate` generation than the live one, in
    /// `CapabilityAxis.allCases` order. A latency difference is not listed.
    case negotiationStale([CapabilityAxis])
    /// The summary's nominal rate differs from the negotiated rate.
    case rateMismatch(summaryHz: Int, negotiatedHz: Int)
    /// The summary has an active loop; a loop is not unwrapped here.
    case loopActive
    /// The block starts before frame 0.
    case negativeFrame(Int64)
    /// The beat position does not fit 64 bits.
    case ticksOverflow
    /// No tempo segment holds the beat position: it is before tick 0.
    case beforeMusicalOrigin(ticks: Int64)
    /// The context was built at another `resources` or `sampleRate` generation than the live one, in
    /// `CapabilityAxis.allCases` order. A latency difference is not listed.
    case contextStale([CapabilityAxis])
}
