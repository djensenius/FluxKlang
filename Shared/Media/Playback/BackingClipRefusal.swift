//
//  BackingClipRefusal.swift
//  FluxKlang
//
//  Typed refusals of the backing-clip spec and voice (#111 PB1). A refused
//  operation leaves the spec inputs and the voice unchanged.
//

/// Why a backing-clip spec, start mapping, voice transition, seek, insert or render is refused.
enum BackingClipRefusal: Error, Equatable, Sendable {
    /// A clip holds at least one frame.
    case totalFramesNotPositive(Int64)
    /// Backing audio plays at the file rate: only `fixedRate` is supported; tempo never changes a voice.
    case unsupportedTimePolicy(MediaTimePolicy)
    /// A loop starts at frame 0 or later.
    case loopStartNegative(Int64)
    /// A loop needs `startFrame < endFrame`.
    case loopNotOrdered(start: Int64, end: Int64)
    /// A loop ends at or before `totalFrames`.
    case loopEndBeyondClip(end: Int64, totalFrames: Int64)
    /// Arming needs the action to be `.ready`; the refusal carries the state found.
    case notReady(ReadinessState)
    /// The action is `.ready` but a recorded dependency is no longer the current generation.
    case staleDependencies
    /// The voice is not armed (`play` or `disarm` from `.disarmed`).
    case notArmed
    case alreadyArmed
    case alreadyPlaying
    /// A render needs a playing voice; the refusal carries the state found (never `.stopped`).
    case notPlaying(BackingVoiceState)
    /// `.stopped` is terminal; the reason it stopped.
    case voiceStopped(BackingStopReason)
    /// A seek lands in `0...totalFrames - 1`.
    case seekOutOfRange(frame: Int64, totalFrames: Int64)
    /// With a loop, one render covers at most one loop length.
    case renderExceedsLoop(frames: Int, loopFrames: Int64)
    /// A cumulative counter ceiling is below zero.
    case counterCeilingNegative(Int64)
    /// The call would push a cumulative counter past the spec's ceiling (or overflow it); nothing changed.
    case counterWouldOverflow(BackingCounter)
    /// The prefetch playhead refused (insert, render length, overflow, generation overflow).
    case prefetch(PrefetchRefusal)
    /// A trigger outcome failed `TriggerOutcome.validateMediaShape()`; no start was mapped.
    case malformedOutcome(TriggerOutcomeValidationError)
}
