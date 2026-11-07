/// What a bridge event carries: one UMP packet or one parameter ramp.
enum BridgeEventPayload: Equatable, Sendable {
    case midi(UMPPacket)
    case ramp(BridgeParameterRamp)
}

/// A plugin event planned for a block-relative frame offset under a capability generation.
///
/// This is a PLAN: it records the generation it was planned under and is judged against the live generation, the block
/// and the negotiated spec only by `BridgeEventBatch.validate`. The offset is block-relative (not the absolute
/// `KernelEvent.frame`; converting between them is deferred). A value exists only if `make` accepted it; the offset is
/// never negative. It holds no reference and no closure, so it cannot mutate authority.
struct BridgeEvent: Equatable, Sendable {
    let frameOffset: Int
    let payload: BridgeEventPayload
    let planned: CapabilityGeneration

    private init(frameOffset: Int, payload: BridgeEventPayload, planned: CapabilityGeneration) {
        self.frameOffset = frameOffset
        self.payload = payload
        self.planned = planned
    }

    /// Throws `.negativeOffset` for an offset below zero; every other check needs the live block and is made by
    /// `BridgeEventBatch.validate`.
    static func make(
        frameOffset: Int, payload: BridgeEventPayload, planned: CapabilityGeneration
    ) throws(BridgeEventRefusal) -> BridgeEvent {
        guard frameOffset >= 0 else { throw .negativeOffset(frameOffset) }
        return BridgeEvent(frameOffset: frameOffset, payload: payload, planned: planned)
    }
}
