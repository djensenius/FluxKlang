/// One render callback as the host sees it: the frame count, the generation stamp the caller holds and the enabled
/// bus counts it intends to supply buffers for.
///
/// A plain value: it arrives from a render callback and is judged by `DispatchGuard`, never trapped on. There are no
/// AudioToolbox types here; the AU adapter maps `AUAudioFrameCount`/`AudioBufferList` onto this request.
struct DispatchRequest: Hashable, Sendable {
    let frames: Int
    let stamp: CapabilityGeneration
    let inputBuses: Int
    let outputBuses: Int
}

/// What the host may do for one callback; it carries no payload, buffer or text.
enum DispatchDecision: Hashable, Sendable {
    case dispatch(frames: Int)
    case idle
    case silence(DispatchSilenceReason)
}

/// Why a callback was answered with silence instead of a plugin call.
enum DispatchSilenceReason: Hashable, Sendable {
    case invalidFrameCount(Int)
    case staleResources
    case staleSampleRate
    case busShapeMismatch(inputs: Int, outputs: Int)
    case oversizedCallback(frames: Int, maximum: Int)
}

/// Decides, BEFORE any plugin call, whether a callback may dispatch, idle or must be silenced.
///
/// Total and non-throwing; it holds no state and allocates nothing in intent. Oversized callbacks are refused whole
/// (silence), never split into chunks. The latency axis is ignored by design: a latency change does not make buffers
/// unsafe. A callback is stale on an axis when EITHER the negotiated generation OR the request's own stamp differs
/// from the live one (a deliberate, conservative reading: the lane sheet names only the negotiated generation, so the
/// stamp is additionally honoured and can only cause silence, never a dispatch). Checks, first failure wins: negative
/// frames, stale resources, stale sample rate, enabled bus counts, oversized (`frames > maximumFrames`; equal
/// dispatches), zero frames (idle), otherwise dispatch. No AudioToolbox
/// types here; the AU adapter maps `AUAudioFrameCount`/`AudioBufferList` onto `DispatchRequest`.
enum DispatchGuard {
    static func decide(
        _ request: DispatchRequest, negotiated: NegotiatedRender, live: CapabilityGeneration
    ) -> DispatchDecision {
        let frames = request.frames
        let spec = negotiated.spec
        if frames < 0 { return .silence(.invalidFrameCount(frames)) }
        if isStale(negotiated.generation.resources, request.stamp.resources, live: live.resources) {
            return .silence(.staleResources)
        }
        if isStale(negotiated.generation.sampleRate, request.stamp.sampleRate, live: live.sampleRate) {
            return .silence(.staleSampleRate)
        }
        if request.inputBuses != spec.enabledInputCount || request.outputBuses != spec.enabledOutputCount {
            return .silence(.busShapeMismatch(inputs: request.inputBuses, outputs: request.outputBuses))
        }
        if frames > spec.maximumFrames {
            return .silence(.oversizedCallback(frames: frames, maximum: spec.maximumFrames))
        }
        return frames == 0 ? .idle : .dispatch(frames: frames)
    }

    private static func isStale(_ negotiated: Generation, _ stamp: Generation, live: Generation) -> Bool {
        negotiated != live || stamp != live
    }
}
