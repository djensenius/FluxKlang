/// Numeric bounds of the event bridge.
enum BridgeEventLimits {
    /// Events one batch may hold; 4,096 are accepted and 4,097 refuse the whole batch.
    static let maximumEventsPerBatch = 4_096
}

/// One event the validator refused: its index in the input batch and why.
struct RejectedBridgeEvent: Equatable, Sendable {
    let index: Int
    let reason: BridgeEventRefusal
}

/// The outcome of validating one batch: the accepted events and the rejected ones.
///
/// `accepted` is ordered by ascending (frame offset, input index), so equal offsets keep their input order.
/// `rejected` is ordered by ascending input index. A rejected event never aborts the batch. Only
/// `BridgeEventBatch.validate` can build a `BridgeBatchDecision`; the `RejectedBridgeEvent` records inside it have an
/// internal memberwise initialiser and can be built anywhere.
struct BridgeBatchDecision: Equatable, Sendable {
    let accepted: [BridgeEvent]
    let rejected: [RejectedBridgeEvent]

    fileprivate init(accepted: [BridgeEvent], rejected: [RejectedBridgeEvent]) {
        self.accepted = accepted
        self.rejected = rejected
    }
}

/// Judges planned events against the negotiated render, the live generation and the current block.
///
/// Pure: the result depends only on the arguments, and the only failure is the typed whole-batch refusal.
/// It runs on the control thread: it takes and returns arrays,
/// so it makes no real-time or allocation-free claim. Nothing is mutated; the input array is never changed.
enum BridgeEventBatch {
    /// Throws `.batchTooLarge(count)` for more than `BridgeEventLimits.maximumEventsPerBatch` events, before any event
    /// is judged. Otherwise each event is judged alone and the first failure wins: block (`invalidBlock` for a block
    /// below 1, `blockExceedsNegotiated` above `negotiated.spec.maximumFrames`, `negotiationStale` when the spec was
    /// negotiated at another `resources` or `sampleRate` generation than `live`), then `stale`, then
    /// `offsetBeyondBlock`, then `unsupportedPacket`.
    ///
    /// A MIDI event is stale on any differing axis; a ramp binds `resources` and `sampleRate` only. An empty batch is
    /// legal and yields an empty decision whatever the block is.
    static func validate(
        _ events: [BridgeEvent], against negotiated: NegotiatedRender, live: CapabilityGeneration, blockFrames: Int
    ) throws(BridgeEventRefusal) -> BridgeBatchDecision {
        guard events.count <= BridgeEventLimits.maximumEventsPerBatch else { throw .batchTooLarge(events.count) }
        let blockFault = blockRefusal(negotiated, live: live, blockFrames: blockFrames)
        var accepted: [(index: Int, event: BridgeEvent)] = []
        var rejected: [RejectedBridgeEvent] = []
        for (index, event) in events.enumerated() {
            if let reason = blockFault ?? refusal(for: event, live: live, blockFrames: blockFrames) {
                rejected.append(RejectedBridgeEvent(index: index, reason: reason))
            } else {
                accepted.append((index, event))
            }
        }
        accepted.sort { lhs, rhs in
            lhs.event.frameOffset != rhs.event.frameOffset
                ? lhs.event.frameOffset < rhs.event.frameOffset : lhs.index < rhs.index
        }
        return BridgeBatchDecision(accepted: accepted.map(\.event), rejected: rejected)
    }

    private static func blockRefusal(
        _ negotiated: NegotiatedRender, live: CapabilityGeneration, blockFrames: Int
    ) -> BridgeEventRefusal? {
        guard blockFrames >= 1 else { return .invalidBlock(blockFrames) }
        let maximum = negotiated.spec.maximumFrames
        guard blockFrames <= maximum else {
            return .blockExceedsNegotiated(blockFrames: blockFrames, maximumFrames: maximum)
        }
        let stale = negotiated.generation.staleAxes(comparedTo: live).filter { $0 != .latency }
        return stale.isEmpty ? nil : .negotiationStale(stale)
    }

    private static func refusal(
        for event: BridgeEvent, live: CapabilityGeneration, blockFrames: Int
    ) -> BridgeEventRefusal? {
        var stale = event.planned.staleAxes(comparedTo: live)
        if case .ramp = event.payload { stale.removeAll { $0 == .latency } }
        if !stale.isEmpty { return .stale(stale) }
        guard event.frameOffset < blockFrames else {
            return .offsetBeyondBlock(offset: event.frameOffset, blockFrames: blockFrames)
        }
        if case .midi(let packet) = event.payload {
            switch packet.messageType {
            case .system, .midi1ChannelVoice, .data64, .midi2ChannelVoice: break
            default: return .unsupportedPacket(packet.messageType)
            }
        }
        return nil
    }
}
