//
//  BackingClipStart.swift
//  FluxKlang
//
//  Where a backing-clip voice starts for one scheduler `TriggerOutcome`
//  (#111 BJ1). A pure value: no clock, I/O or voice state.
//
//  media-contract.md §6.3 (`joinInProgress`): "If lateness ≤ `maxLatenessMs`:
//  `joined` at the horizon with `startOffsetFrames = horizon − assigned`, so the
//  source stays aligned. Otherwise `dropped` (`late`)".
//  media-contract.md §8.1 (audio): `fixedRate` by default, "sample-rate conversion
//  is not stretching"; and the #111 row: "Backing clips are `fixedRate` by
//  default and use `joinInProgress`".
//  `BackingClipRefusal.unsupportedTimePolicy`: "Backing audio plays at the file
//  rate". The voice maps output frames 1:1 to source frames, so a join offset of
//  N output frames is N source frames from frame 0, folded as the voice renders.
//

/// What a backing-clip voice does for one trigger outcome. Outcomes that do not start the clip are values, not
/// refusals: `cancelled`, `rejectedStale` and `dropped` are valid terminal scheduler results and an ended join is
/// a valid late join, while `BackingClipRefusal` means "invalid input, nothing changed".
///
/// The scheduler's diagnostic drops (`dropped` with `invalidTiming`, or `outsideLoop` with a `musicalMap`) are not
/// v1 media outcomes: `validateMediaShape()` rejects them, so they are refused as `.malformedOutcome`. Their shape
/// check lives only inside `TriggerSession.completeDiagnostic`; the caller treats such a refusal as not started.
enum BackingClipStart: Equatable, Sendable {
    /// Start playing at this source frame, in `0..<totalFrames`.
    case start(frame: Int64)
    /// A `joined` outcome whose offset reaches or passes the end of a clip without a loop: the clip is over.
    case ended(startOffsetFrames: Int64)
    /// `cancelled`, `rejectedStale` or `dropped`: the voice does not start.
    case notStarted(OutcomeResult)

    /// Maps a scheduler outcome onto `spec`. Checks, in this order: the outcome's media shape
    /// (`TriggerOutcome.validateMediaShape()`, refused as `.malformedOutcome`), then the result:
    /// - `fired`, `firedLate`: `.start(frame: 0)`.
    /// - `joined`: `startOffsetFrames` folded into the clip. Without a loop it starts there when below
    ///   `totalFrames`, else `.ended`. With a loop `[start, end)`, an offset below `end` is used as is and one at or
    ///   past `end` folds to `start + (offset − end) % loopFrames`, the frame the voice reaches by rendering
    ///   `offset` frames from frame 0 (it wraps only while `position < end`).
    /// - `cancelled`, `rejectedStale`, `dropped`: `.notStarted(result)`.
    ///
    /// `TriggerOutcome` carries only its trigger ID, not the action, so the caller pairs the outcome with the
    /// spec of the trigger's action; that pairing is not checked here.
    static func make(outcome: TriggerOutcome, spec: BackingClipSpec) throws(BackingClipRefusal) -> BackingClipStart {
        do throws(TriggerOutcomeValidationError) {
            try outcome.validateMediaShape()
        } catch {
            throw .malformedOutcome(error)
        }
        switch outcome.result {
        case .fired, .firedLate: return .start(frame: 0)
        case .joined: return joined(offset: outcome.startOffsetFrames, spec: spec)
        case .cancelled, .rejectedStale, .dropped: return .notStarted(outcome.result)
        }
    }

    /// `offset >= 0` (validated). No step can overflow: `offset − end` has both sides in `0...Int64.max`, and the
    /// folded frame is below `end`.
    private static func joined(offset: Int64, spec: BackingClipSpec) -> BackingClipStart {
        guard let loop = spec.loop, let loopFrames = spec.loopFrames else {
            return offset < spec.totalFrames ? .start(frame: offset) : .ended(startOffsetFrames: offset)
        }
        guard offset >= loop.endFrame else { return .start(frame: offset) }
        return .start(frame: loop.startFrame + (offset - loop.endFrame) % loopFrames)
    }
}

extension BackingClipVoice {
    /// Moves the voice to where `start` begins; it never arms or plays. Returns true for `.start` (the caller may
    /// then `play`), false for `.ended` and `.notStarted`, which leave the voice unchanged.
    ///
    /// For `.start(frame:)` away from `position` this is `seek(to:)`: a new read, so the read generation advances,
    /// resident blocks are dropped, and the next render reports one `.locate`. Until blocks for the new read
    /// generation are inserted, that render underruns under the spec's declared `BackingUnderrunPolicy` (silence
    /// and report, or stop the voice). At `position` already, nothing changes and the prefetched blocks are kept.
    /// Refusals: stopped first (for every `start`), then those of `seek(to:)`.
    @discardableResult
    mutating func locate(to start: BackingClipStart) throws(BackingClipRefusal) -> Bool {
        try requireNotStopped()
        guard case .start(let frame) = start else { return false }
        if frame != position { try seek(to: frame) }
        return true
    }
}
