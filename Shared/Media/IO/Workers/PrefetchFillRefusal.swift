//
//  PrefetchFillRefusal.swift
//  FluxKlang
//
//  Typed refusals of the prefetch fill pump (#109 IO2, media-contract.md
//  §8.2). A refused call leaves the pump `==`-identical, counters included.
//  Payloads are counts, frames and ids only, never text.
//

/// Why a `PrefetchFillPump` call is refused.
enum PrefetchFillRefusal: Error, Equatable, Sendable {
    /// A source holds at least one frame.
    case sourceFramesNotPositive(Int64)
    /// Source generations are at least 1.
    case sourceGenerationNotPositive
    /// Positions are never negative.
    case negativePosition(Int64)
    /// A position lies in `0...sourceFrames`; `sourceFrames` itself means "already at the end".
    case positionBeyondSource(position: Int64, sourceFrames: Int64)
    /// The resident block count lies in `0...maximum` (the plan's `blockCount`).
    case residentBlocksOutOfRange(count: Int, maximum: Int)
    /// The id is neither the ticket in flight nor the remembered abandoned one.
    case unknownTicket(UInt64)
    /// A worker reported a frame count outside `0...requested`.
    case deliveredFramesOutOfRange(delivered: Int, requested: Int)
    /// The delivered block was refused by `PrefetchBlock.make`; unreachable for a pump-issued ticket.
    case blockRefused(PrefetchRefusal)
    /// The read generation is already `UInt64.max`.
    case generationOverflow
    /// A resumed source generation must be strictly newer than the current one.
    case generationNotNewer(current: UInt64, proposed: UInt64)
    /// `resume` is only meaningful after a latched fault.
    case notFailed
    /// The ticket id counter is exhausted. Unreachable through the public API (2^64 tickets); the guard has no mutant.
    case ticketCounterOverflow
}
