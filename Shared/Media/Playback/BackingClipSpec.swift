//
//  BackingClipSpec.swift
//  FluxKlang
//
//  The validated description of one backing clip (#111 PB1): the action it
//  belongs to, its length in source frames, an optional loop and the declared
//  time and underrun policies. Build it with `make`.
//

/// What a playing voice does when the prefetch pool cannot supply a frame.
enum BackingUnderrunPolicy: Equatable, Sendable {
    /// Output silence for the missing frames, report the underrun and keep playing.
    case silenceAndReport
    /// Report the first underrun and stop the voice (`.underrun`) after the frames already resolved.
    case stopVoice
}

/// A caller-built loop region `[startFrame, endFrame)`. It is validated again by `BackingClipSpec.make`.
struct BackingClipLoop: Equatable, Sendable {
    let startFrame: Int64
    let endFrame: Int64
}

/// A validated backing clip. `timePolicy` is always `fixedRate`, so a tempo change can never affect the voice.
struct BackingClipSpec: Equatable, Sendable {
    var action: ActionID { storedAction }
    var totalFrames: Int64 { storedTotalFrames }
    var loop: BackingClipLoop? { storedLoop }
    var underrun: BackingUnderrunPolicy { storedUnderrun }
    /// The loop's length in frames, or nil without a loop.
    var loopFrames: Int64? { storedLoop.map { $0.endFrame - $0.startFrame } }

    private let storedAction: ActionID
    private let storedTotalFrames: Int64
    private let storedLoop: BackingClipLoop?
    private let storedUnderrun: BackingUnderrunPolicy
    private let storedCounterCeiling: Int64

    /// The largest value any cumulative counter of a voice may reach (default `Int64.max`).
    var counterCeiling: Int64 { storedCounterCeiling }

    private init(validatedAction action: ActionID, totalFrames: Int64, loop: BackingClipLoop?,
                 underrun: BackingUnderrunPolicy, counterCeiling: Int64) {
        storedAction = action
        storedTotalFrames = totalFrames
        storedLoop = loop
        storedUnderrun = underrun
        storedCounterCeiling = counterCeiling
    }

    /// A copy with a cumulative counter ceiling in `0...Int64.max`. A test seam for the counter guards: tests set it
    /// low to reach the overflow bound; production code leaves the default.
    func withCounterCeiling(_ ceiling: Int64) throws(BackingClipRefusal) -> BackingClipSpec {
        guard ceiling >= 0 else { throw .counterCeilingNegative(ceiling) }
        return BackingClipSpec(validatedAction: storedAction, totalFrames: storedTotalFrames, loop: storedLoop,
                               underrun: storedUnderrun, counterCeiling: ceiling)
    }

    /// Checks, in this order: `totalFrames >= 1`, `timePolicy == .fixedRate`, then the loop
    /// (`0 <= start`, `start < end`, `end <= totalFrames`).
    static func make(action: ActionID, totalFrames: Int64, loop: BackingClipLoop?, timePolicy: MediaTimePolicy,
                     underrun: BackingUnderrunPolicy) throws(BackingClipRefusal) -> BackingClipSpec {
        guard totalFrames >= 1 else { throw .totalFramesNotPositive(totalFrames) }
        guard timePolicy == .fixedRate else { throw .unsupportedTimePolicy(timePolicy) }
        if let loop {
            guard loop.startFrame >= 0 else { throw .loopStartNegative(loop.startFrame) }
            guard loop.startFrame < loop.endFrame else {
                throw .loopNotOrdered(start: loop.startFrame, end: loop.endFrame)
            }
            guard loop.endFrame <= totalFrames else {
                throw .loopEndBeyondClip(end: loop.endFrame, totalFrames: totalFrames)
            }
        }
        return BackingClipSpec(validatedAction: action, totalFrames: totalFrames, loop: loop, underrun: underrun,
                               counterCeiling: Int64.max)
    }
}

/// Which cumulative counter a refusal is about.
enum BackingCounter: Equatable, Sendable {
    case underrunFrames
    case discardedStaleBlocks
}

/// The overflow guard run before a counter is advanced by PF1 or the voice.
enum BackingCounterGuard {
    /// True when `current + adding` neither overflows nor passes `ceiling`; negative inputs are never admitted.
    static func capacityAdmits(current: Int64, adding: Int64, ceiling: Int64) -> Bool {
        guard current >= 0, adding >= 0 else { return false }
        let (sum, overflow) = current.addingReportingOverflow(adding)
        return !overflow && sum <= ceiling
    }
}
