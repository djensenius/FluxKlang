//
//  CaptureDrainTypes.swift
//  FluxKlang
//
//  The plain values of the capture write drain pump (#109 WDP1,
//  media-contract.md §8.3): limits, state, steps, outcomes, the padded
//  interval, the summary and the counters. Values carry counts, frames and
//  ids only, never sample payload.
//

/// The bounds of the capture write drain pump. Every bound is accepted at N and refused at N + 1.
enum CaptureDrainLimits {
    /// The most blocks one pump queues; the largest prefetch pool holds this many blocks.
    static let maximumPendingBlocks = PrefetchPlan.blockCountRange.upperBound
    /// The most consecutive failures of one range the pump retries; the next one latches the fault.
    static let maximumRetries = MediaIOLimits.maximumConsecutiveRetries
    /// The most frames one padded interval covers; the width of a discontinuity's frame count.
    static let maximumPaddingFrames = Int(UInt32.max)
}

/// Where a pump is in its life.
enum CaptureDrainState: Equatable, Sendable {
    case running
    /// A fault latched; the queue is kept and handed back by `reclaim`.
    case stopped(MediaWriteFault)
    case finished
}

/// A stretch of the stream that holds no captured frames; the adapter writes the silence and reports it as
/// `MediaIOFaultMapping.writerBackpressureKind`.
struct CaptureDrainOverflow: Equatable, Sendable {
    let startFrame: Int64
    let frames: Int
}

/// Why `nextWrite` issued nothing; a statement about the writer, never an instruction to the recorder.
enum CaptureDrainIdle: Equatable, Sendable {
    case stopped
    case finished
    case inFlight
    case empty
}

enum CaptureDrainStep: Equatable, Sendable {
    case write(CaptureDrainTicket)
    case idle(CaptureDrainIdle)
}

enum CaptureDrainEnqueue: Equatable, Sendable {
    /// The block was stored; `pending` blocks are now queued.
    case queued(pending: Int)
    /// The queue was full: the newest block was padded and its lease is handed back for release.
    case padded(CaptureDrainOverflow, returning: MediaBlockLease)
    /// The pump had stopped: the block was not queued and its lease is handed back for release.
    case stopped(reason: RuntimeCaptureStopReason, returning: MediaBlockLease)
}

enum CaptureDrainPadResult: Equatable, Sendable {
    case padded(CaptureDrainOverflow)
    case stopped(reason: RuntimeCaptureStopReason)
}

enum CaptureDrainOutcome: Equatable, Sendable {
    case stillPending(polls: UInt64)
    /// The writer took `accepted` frames; `remaining` of the block are resubmitted by the next `nextWrite` with
    /// `blockOffset` set to the frames already accepted.
    case partial(accepted: Int, remaining: Int)
    /// The block is fully written; the caller releases its lease.
    case blockWritten(CaptureDrainBlock)
    case retryScheduled(attempt: Int)
    /// A fault latched. Reported once; the queue is kept.
    case captureStopped(reason: RuntimeCaptureStopReason, fault: MediaWriteFault)
}

enum CaptureDrainSealing: Equatable, Sendable {
    case sealed(durableFrames: Int64)
    case sealFailed(MediaWriteFault)
}

/// What one capture run achieved. `streamFrames == acceptedFrames + paddedFrames + unwrittenFrames +
/// reclaimedFrames`. Pump-built; do not construct.
struct CaptureDrainSummary: Equatable, Sendable {
    let startFrame: Int64
    let streamFrames: Int64
    let acceptedFrames: Int64
    let paddedFrames: Int64
    let unwrittenFrames: Int64
    let reclaimedFrames: Int64
    let sealing: CaptureDrainSealing
    /// The latched reason, or nil for a user stop (the pump never reports a user stop itself).
    let stopReason: RuntimeCaptureStopReason?

    /// True when a sealed file holds fewer frames than were accepted; a failed seal reports nothing.
    var isPartial: Bool {
        guard case .sealed(let durable) = sealing else { return false }
        return durable < acceptedFrames
    }

    /// Accepted frames missing from a sealed file; zero for a failed seal. Precondition, true of every pump-built
    /// summary: `acceptedFrames >= durable >= 0` (a sealed result never reports more than was accepted).
    var missingFrames: Int64 {
        guard case .sealed(let durable) = sealing else { return 0 }
        return acceptedFrames - durable
    }
}

/// Counters that saturate at `UInt64.max`, never decrease and are untouched by a refusal.
struct CaptureDrainCounters: Equatable, Sendable {
    private(set) var ticketsIssued: UInt64 = 0
    private(set) var blocksQueued: UInt64 = 0
    private(set) var blocksWritten: UInt64 = 0
    private(set) var shortAccepts: UInt64 = 0
    private(set) var slowPolls: UInt64 = 0
    private(set) var retriesScheduled: UInt64 = 0
    private(set) var backpressureBlocks: UInt64 = 0
    private(set) var framesAfterStop: UInt64 = 0
    private(set) var faultsLatched: UInt64 = 0
    private(set) var blocksReclaimed: UInt64 = 0

    /// Every counter in declaration order, for monotonicity checks.
    var values: [UInt64] {
        [ticketsIssued, blocksQueued, blocksWritten, shortAccepts, slowPolls, retriesScheduled, backpressureBlocks,
         framesAfterStop, faultsLatched, blocksReclaimed]
    }

    mutating func noteIssued() { ticketsIssued = Self.bump(ticketsIssued, 1) }
    mutating func noteQueued() { blocksQueued = Self.bump(blocksQueued, 1) }
    mutating func noteWritten() { blocksWritten = Self.bump(blocksWritten, 1) }
    mutating func noteShortAccept() { shortAccepts = Self.bump(shortAccepts, 1) }
    mutating func noteSlowPoll() { slowPolls = Self.bump(slowPolls, 1) }
    mutating func noteRetry() { retriesScheduled = Self.bump(retriesScheduled, 1) }
    mutating func noteBackpressure() { backpressureBlocks = Self.bump(backpressureBlocks, 1) }
    mutating func noteLatched() { faultsLatched = Self.bump(faultsLatched, 1) }
    mutating func noteReclaimed() { blocksReclaimed = Self.bump(blocksReclaimed, 1) }
    mutating func noteAfterStop(frames: Int) { framesAfterStop = Self.bump(framesAfterStop, UInt64(max(frames, 0))) }

    private static func bump(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        PrefetchFillCounters.saturatingSum(value, amount)
    }
}
