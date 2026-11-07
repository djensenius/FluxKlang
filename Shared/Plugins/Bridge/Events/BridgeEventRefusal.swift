/// Why a bridge event, or a whole batch, was refused. Values carry numbers, axes and types only, never text.
///
/// Per-event refusals are checked in this order and the first failure wins: block (`invalidBlock`,
/// `blockExceedsNegotiated`, `negotiationStale`), `stale`, `offsetBeyondBlock`, `unsupportedPacket`. `negativeOffset`
/// is thrown by `BridgeEvent.make`; `batchTooLarge` is thrown for a whole batch before any event is judged.
enum BridgeEventRefusal: Error, Hashable, Sendable {
    case negativeOffset(Int)
    case batchTooLarge(Int)
    case invalidBlock(Int)
    case blockExceedsNegotiated(blockFrames: Int, maximumFrames: Int)
    /// The negotiated spec was recorded at another `resources`/`sampleRate` generation than the live one.
    case negotiationStale([CapabilityAxis])
    /// The event was planned under other generations than the live ones, in `CapabilityAxis.allCases` order.
    case stale([CapabilityAxis])
    case offsetBeyondBlock(offset: Int, blockFrames: Int)
    case unsupportedPacket(UMPMessageType)
}
