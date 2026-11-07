//
//  PrefetchFillTypes.swift
//  FluxKlang
//
//  The value vocabulary of the prefetch fill pump (#109 IO2, media-contract.md
//  §8.2): states, wait reasons, steps, outcomes and saturating counters. The
//  pump itself is in PrefetchFillPump.swift.
//

/// Where one pump is in its read cycle. `failed` is left only by `PrefetchFillPump.resume`.
enum PrefetchFillState: Equatable, Sendable {
    /// No read in flight; the next `nextRequest` may issue one.
    case idle
    /// One ticket is in flight.
    case awaitingCompletion
    /// The last read failed within the retry budget; the next `nextRequest` re-issues the same range.
    case retrying
    /// The source has no frames after `nextFrame`; left by `locate`.
    case ended
    /// A fault is latched; `.sourceLost` was reported once.
    case failed(MediaReadFault)
}

/// Why `nextRequest` issued nothing, listed in the order the pump checks them.
enum PrefetchFillWait: Equatable, Sendable {
    case failed
    case inFlight
    case ended
    case poolFull
    case satisfied
}

/// What `nextRequest` decided: read one more block, or wait for a stated reason.
enum PrefetchFillStep: Equatable, Sendable {
    case request(PrefetchFillTicket)
    case wait(PrefetchFillWait)
}

/// A block the worker filled, ready for `PrefetchPlayhead.insert`.
///
/// A plain output value, deliberately constructible by tests and adapters: it grants nothing, because
/// `PrefetchBlock` is itself validated and the playhead re-checks every insert.
struct PrefetchFillDelivery: Equatable, Sendable {
    let block: PrefetchBlock
    /// True exactly once, on the first delivery after `resume` (the mapping turns it into `sourceRestored`).
    let restoredSource: Bool
    /// The block ends the source: the worker said so, or `block.endFrame == sourceFrames`.
    let reachedEnd: Bool
}

/// What a completion did to the pump. Retries, stale discards and slow reads are counted, not discontinuities.
enum PrefetchFillOutcome: Equatable, Sendable {
    case delivered(PrefetchFillDelivery)
    case endedWithoutData
    /// The read is still pending after `polls` consecutive pending polls (1...8).
    case stillPending(polls: Int)
    /// The failed range will be re-issued; `attempt` is the number of consecutive failures (1...3).
    case retryScheduled(attempt: Int)
    /// The fault was latched; emitted exactly once per latch.
    case sourceLost(MediaReadFault)
    /// A late completion of an abandoned ticket; its payload was not inspected.
    case discardedStale
}

/// Pump counters. Every counter only increases and SATURATES at `UInt64.max`; a refused call changes none.
struct PrefetchFillCounters: Equatable, Sendable {
    private(set) var ticketsIssued: UInt64 = 0
    private(set) var blocksDelivered: UInt64 = 0
    private(set) var framesDelivered: UInt64 = 0
    private(set) var shortReads: UInt64 = 0
    private(set) var retriesScheduled: UInt64 = 0
    private(set) var stalls: UInt64 = 0
    private(set) var staleCompletions: UInt64 = 0
    private(set) var ticketsAbandoned: UInt64 = 0
    private(set) var faultsLatched: UInt64 = 0
    private(set) var earlyEnds: UInt64 = 0
    private(set) var framesSkipped: UInt64 = 0

    /// Every counter in declaration order, for monotonicity checks.
    var values: [UInt64] {
        [ticketsIssued, blocksDelivered, framesDelivered, shortReads, retriesScheduled, stalls, staleCompletions,
         ticketsAbandoned, faultsLatched, earlyEnds, framesSkipped]
    }

    /// `lhs + rhs`, or `UInt64.max` when the sum would overflow.
    static func saturatingSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    /// A ticket was issued; `skipped` (never negative) source frames were passed over to follow the consumer.
    mutating func noteIssued(skipped: Int64) {
        ticketsIssued = Self.saturatingSum(ticketsIssued, 1)
        framesSkipped = Self.saturatingSum(framesSkipped, UInt64(max(skipped, 0)))
    }

    /// A block of `frames` frames (at least 1) was delivered.
    mutating func noteDelivery(frames: Int) {
        blocksDelivered = Self.saturatingSum(blocksDelivered, 1)
        framesDelivered = Self.saturatingSum(framesDelivered, UInt64(max(frames, 0)))
    }

    mutating func noteShortRead() { shortReads = Self.saturatingSum(shortReads, 1) }
    mutating func noteRetryScheduled() { retriesScheduled = Self.saturatingSum(retriesScheduled, 1) }
    mutating func noteStall() { stalls = Self.saturatingSum(stalls, 1) }
    mutating func noteStaleCompletion() { staleCompletions = Self.saturatingSum(staleCompletions, 1) }
    mutating func noteAbandoned() { ticketsAbandoned = Self.saturatingSum(ticketsAbandoned, 1) }
    mutating func noteFaultLatched() { faultsLatched = Self.saturatingSum(faultsLatched, 1) }
    mutating func noteEarlyEnd() { earlyEnds = Self.saturatingSum(earlyEnds, 1) }
}
