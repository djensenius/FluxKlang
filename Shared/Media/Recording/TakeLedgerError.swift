//
//  TakeLedgerError.swift
//  FluxKlang
//
//  Why the take ledger refused an input. A refused input changes nothing, except
//  that a stale anchor refusal is remembered as evidence for unplaced segments.
//

/// Which invariant a hand-built take record broke.
enum TakeRecordFault: Hashable, Sendable {
    case frames, nominalRate, placement, overflows, fileContinuity, stopMark
}

enum TakeLedgerError: Error, Equatable, Sendable {
    case invalidTimebase
    case invalidRate(Int)
    case rateMismatch(generation: UInt64)
    case tooManyTakes
    case tooManySegments
    case tooManyOverflows
    /// Anchors or restarts beyond `TakeLedger.maximumGenerationRecords`.
    case tooManyGenerationRecords
    case duplicateTake(TakeID)
    case unknownTake(TakeID)
    /// Finishing seals a take; it accepts nothing afterwards.
    case takeSealed(TakeID)
    /// Another open take already records this stream slot.
    case streamBusy(StreamID)
    case streamMismatch
    case clockMismatch
    case missingStream
    case generationOutOfRange(UInt64)
    /// A newer generation of the clock is already known.
    case staleGeneration(UInt64)
    case generationMismatch(expected: UInt64, actual: UInt64)
    /// An open take is behind a clock restart's previous generation, or a jump's generation.
    case missedRestart(TakeID)
    case progressRegressed(frontier: Int64, frame: Int64)
    /// A segment continuing across a restart must end exactly at its `previousFrame`.
    case segmentEndMismatch(frontier: Int64, previousFrame: Int64)
    /// The take captured no frames at all; there is nothing to finalize.
    case emptySegment
    case tooManyBoundaries
    case missingOverflowFrames
    /// The overflow interval is not wholly inside the captured part of its segment.
    case overflowOutsideSegment(startFrame: Int64, endFrame: Int64)
    case overflowOverlapsPrevious(startFrame: Int64)
    /// A `captureStopped` must sit at the end of the take's last segment.
    case stopNotAtEnd(frame: Int64, frontier: Int64)
    case duplicateCaptureStopped
    /// Capture has stopped; no more progress or segments.
    case captureAlreadyStopped
    case stopReasonMismatch(expected: TakeStopReason, recorded: TakeStopReason)
    case missingCaptureStopped(TakeStopReason)
    /// Only `overflow` and `captureStopped` records are appended to a take.
    case unsupportedDiscontinuity
    /// A `captureStopped` on a stream an open take records, owned by no take.
    case recordNotOwned(stream: UInt32, frame: Int64)
    /// A stopped take's stop lies past the restart's `previousFrame` (§8.3).
    case stopAfterRestart(TakeID, stopFrame: Int64, previousFrame: Int64)
    /// A stored segment of the generation the restart ends, such as one closed before a backward
    /// jump, lies past its `previousFrame` (§8.3). Refused, never trimmed.
    case segmentAfterRestart(TakeID, segmentEnd: Int64, previousFrame: Int64)
    /// `noCapturedFrames` names a take that holds frames.
    case discardReasonMismatch(TakeDiscardReason)
    case inconsistentRecord(TakeRecordFault)
    case arithmeticOverflow
    case negativeLatency(Int64)
    case invalidLatencyEvidence(bytes: Int)
}
