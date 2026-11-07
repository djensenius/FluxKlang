//
//  MediaIOFault.swift
//  FluxKlang
//
//  The closed faults of the off-render reader and writer workers (#109 IO2,
//  media-contract.md §8.2, §8.3). A fault carries no payload: no error text,
//  no file URL, no `NSError`. "Slow", "short read" and "partial file" are NOT
//  faults: they are `MediaReadPoll.pending`, a `ready` result below the request
//  and a `MediaWriteFinish` whose `durableFrames < acceptedFrames`.
//

/// Why a reader worker could not deliver a read.
enum MediaReadFault: String, CaseIterable, Error, Hashable, Sendable {
    /// The asset cannot be opened or has vanished. Terminal: the fill pump never retries it.
    case unavailable
    /// The read failed. Retryable up to `MediaIOLimits.maximumConsecutiveRetries`.
    case ioFailure
    /// The read was interrupted before completion. Retried exactly like `ioFailure`.
    case interrupted
}

/// Why a writer worker could not take a write or seal its file.
enum MediaWriteFault: String, CaseIterable, Error, Hashable, Sendable {
    /// The destination cannot be opened or has vanished. Terminal.
    case unavailable
    /// The write failed.
    case ioFailure
    /// The write was interrupted before completion.
    case interrupted
    /// The destination has no room left. Terminal; the file written so far stays recoverable (§8.3).
    case diskFull
}
