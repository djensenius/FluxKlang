//
//  BackingRender.swift
//  FluxKlang
//
//  The vocabulary of a backing-clip voice (#111 PB1): its state, why it stopped,
//  the result of one render and an equatable snapshot used to prove that a
//  refused operation changed nothing.
//

/// Why a voice is `.stopped`. A stopped voice is terminal: make a new one.
enum BackingStopReason: Equatable, Sendable {
    /// `stop()` was called.
    case requested
    /// The playhead reached `totalFrames` (without a loop that covers the clip end).
    case reachedEnd
    /// The first underrun under `BackingUnderrunPolicy.stopVoice`.
    case underrun
    /// The action stopped being current while the voice was armed or playing; it never re-arms by itself.
    case readinessLost
}

/// The state of a `BackingClipVoice`. A new voice is always `.disarmed`.
enum BackingVoiceState: Equatable, Sendable {
    case disarmed
    case armed
    case playing
    case stopped(BackingStopReason)
}

/// How one render ended. `unrenderedFrames` is the part of the request that was not rendered; it is never an underrun.
enum BackingRenderOutcome: Equatable, Sendable {
    /// All requested frames were rendered and the voice kept playing.
    case complete
    /// The render was truncated at the loop end and the voice wrapped (a new read); the owner refills the loop head
    /// for `BackingRender.readGeneration` (the value after this render) and renders the remainder in a new call.
    case loopWrapped(unrenderedFrames: Int)
    /// The playhead reached `totalFrames`; the voice stopped with `.reachedEnd`.
    case reachedEnd(unrenderedFrames: Int)
    /// `.stopVoice` stopped the voice at its first missing frame.
    case underrunStopped(unrenderedFrames: Int)
}

/// The result of one `BackingClipVoice.render`. One call never straddles a loop wrap.
struct BackingRender: Sendable {
    /// Served and silence runs in output-time order (source frames go backwards only across a wrap between calls).
    let segments: [PrefetchSegment]
    /// `locate` (once, after a seek), `underrun` and `loopWrap` discontinuities in output-time order: the locate at
    /// the first frame, underruns, then the wrap stamped at the sample frame where the wrap happened.
    let discontinuities: [RuntimeDiscontinuity]
    /// Output frames resolved: at most `frames`.
    let renderedFrames: Int
    /// Set when this render stopped the voice.
    let stopped: BackingStopReason?
    let outcome: BackingRenderOutcome
    /// The voice's read generation AFTER this render: the one blocks must carry (it is +1 after a wrap).
    let readGeneration: UInt64
}

/// Every observable field of a voice, for equality checks.
struct BackingVoiceSnapshot: Equatable, Sendable {
    let state: BackingVoiceState
    let position: Int64
    let sourceGeneration: UInt64
    let readGeneration: UInt64
    let blocks: [PrefetchBlock]
    let discardedStaleBlocks: Int
    let underrunFrames: Int64
    let hasPendingLocate: Bool
}
