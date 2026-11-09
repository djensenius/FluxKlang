//
//  CaptureDrainRefusal.swift
//  FluxKlang
//
//  Typed refusals of the capture write drain pump (#109 WDP1,
//  media-contract.md §8.3). A refused call leaves the pump `==`-identical,
//  counters included. Payloads are counts, frames and ids only, never text.
//

/// Why a `CaptureDrainPump` call is refused.
enum CaptureDrainRefusal: Error, Equatable, Sendable {
    /// The pending bound lies in `1...maximum`.
    case pendingBoundOutOfRange(bound: Int, maximum: Int)
    /// A request or a start frame was refused by `MediaWriteRequest.make`.
    case request(MediaIORequestRefusal)
    case alreadyFinished
    /// The lease is already queued; a double write would be possible.
    case leaseAlreadyQueued
    /// Padding covers `1...maximum` frames.
    case paddingFramesOutOfRange(frames: Int, maximum: Int)
    /// The id is not the ticket in flight.
    case unknownTicket(UInt64)
    /// A worker accepted a count outside `1...requested`; a worker that took nothing answers `pending`.
    case acceptedFramesOutOfRange(accepted: Int, requested: Int)
    /// The accepted total does not fit in `Int64`. Not exercised: no public sequence reaches 2^63 frames.
    case acceptedFramesOverflow
    /// `reclaim` is only meaningful after a stop or a finish.
    case notStopped
    case writeInFlight
    /// A running pump must drain before it finishes.
    case blocksStillPending(count: Int)
    /// The worker's accepted count differs from the pump's.
    case acceptedMismatch(worker: Int64, pump: Int64)
    /// The ticket id counter is exhausted. Unreachable through the public API (2^64 tickets); the guard has no mutant.
    case ticketCounterOverflow
}
