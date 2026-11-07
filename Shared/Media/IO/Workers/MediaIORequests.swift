//
//  MediaIORequests.swift
//  FluxKlang
//
//  Validated read and write requests, worker results and the typed refusals
//  of the request factories (#109 IO2, media-contract.md §8.2, §8.3). A
//  request names its destination block by `MediaBlockLease`; the lease is
//  stored and echoed, never validated against a pool here. Requests carry
//  counts and positions only, never sample payload.
//

/// Why a request or a write-finish value is refused. Payloads are counts, frames and positions only.
enum MediaIORequestRefusal: Error, Equatable, Sendable {
    /// `frames` must lie in `1...maximum` (`MediaIOLimits.maximumRequestFrames`).
    case framesOutOfRange(frames: Int, maximum: Int)
    /// Source frame positions are never negative.
    case negativeStartFrame(Int64)
    /// `startFrame + frames` does not fit in `Int64`.
    case frameOverflow(startFrame: Int64, frames: Int)
    /// Source generations are at least 1 (schema `$defs/generation`).
    case sourceGenerationNotPositive
    /// A write-finish count is negative; carries the first negative value (accepted is checked before durable).
    case negativeFrames(Int64)
    /// More frames are durable than were accepted.
    case durableExceedsAccepted(durable: Int64, accepted: Int64)
}

/// The shared span checks, in the documented order: frames range, negative start, `Int64` overflow.
private func validateSpan(startFrame: Int64, frames: Int) throws(MediaIORequestRefusal) {
    guard (1...MediaIOLimits.maximumRequestFrames).contains(frames) else {
        throw .framesOutOfRange(frames: frames, maximum: MediaIOLimits.maximumRequestFrames)
    }
    guard startFrame >= 0 else { throw .negativeStartFrame(startFrame) }
    guard !startFrame.addingReportingOverflow(Int64(frames)).overflow else {
        throw .frameOverflow(startFrame: startFrame, frames: frames)
    }
}

/// One validated request to fill `frames` frames of the leased block from source frame `startFrame`.
/// Build it with `make`; the stored fields are read-only.
struct MediaReadRequest: Hashable, Sendable {
    var lease: MediaBlockLease { storedLease }
    var startFrame: Int64 { storedStartFrame }
    var frames: Int { storedFrames }
    var sourceGeneration: UInt64 { storedSourceGeneration }
    var readGeneration: UInt64 { storedReadGeneration }

    private let storedLease: MediaBlockLease
    private let storedStartFrame: Int64
    private let storedFrames: Int
    private let storedSourceGeneration: UInt64
    private let storedReadGeneration: UInt64

    private init(validatedLease lease: MediaBlockLease, startFrame: Int64, frames: Int, sourceGeneration: UInt64,
                 readGeneration: UInt64) {
        storedLease = lease
        storedStartFrame = startFrame
        storedFrames = frames
        storedSourceGeneration = sourceGeneration
        storedReadGeneration = readGeneration
    }

    /// Order of checks, first failure wins: frames `1...65_536`, non-negative start, `Int64` overflow, source
    /// generation at least 1. `readGeneration` has no lower bound.
    static func make(lease: MediaBlockLease, startFrame: Int64, frames: Int, sourceGeneration: UInt64,
                     readGeneration: UInt64) throws(MediaIORequestRefusal) -> MediaReadRequest {
        try validateSpan(startFrame: startFrame, frames: frames)
        guard sourceGeneration >= 1 else { throw .sourceGenerationNotPositive }
        return MediaReadRequest(validatedLease: lease, startFrame: startFrame, frames: frames,
                                sourceGeneration: sourceGeneration, readGeneration: readGeneration)
    }
}

/// One validated request to write `frames` frames of the leased block at source frame `startFrame`.
/// Build it with `make`; the stored fields are read-only.
struct MediaWriteRequest: Hashable, Sendable {
    var lease: MediaBlockLease { storedLease }
    var startFrame: Int64 { storedStartFrame }
    var frames: Int { storedFrames }

    private let storedLease: MediaBlockLease
    private let storedStartFrame: Int64
    private let storedFrames: Int

    private init(validatedLease lease: MediaBlockLease, startFrame: Int64, frames: Int) {
        storedLease = lease
        storedStartFrame = startFrame
        storedFrames = frames
    }

    /// Order of checks, first failure wins: frames `1...65_536`, non-negative start, `Int64` overflow.
    static func make(lease: MediaBlockLease, startFrame: Int64,
                     frames: Int) throws(MediaIORequestRefusal) -> MediaWriteRequest {
        try validateSpan(startFrame: startFrame, frames: frames)
        return MediaWriteRequest(validatedLease: lease, startFrame: startFrame, frames: frames)
    }
}

/// What a reader worker delivered. Deliberately unvalidated: the fill pump refuses a count outside
/// `0...ticket.frames`, so a fake can script a lying worker.
struct MediaReadResult: Equatable, Sendable {
    /// The first `frames` frames of the request are stored in the leased block.
    let frames: Int
    /// The source has no frames after these.
    let reachedEnd: Bool
}

/// One poll of a read: still working (slow), or a result.
enum MediaReadPoll: Equatable, Sendable {
    case pending
    case ready(MediaReadResult)
}

/// One poll of a write: still working, or the first `frames` frames were taken (a short accept is allowed).
enum MediaWritePoll: Equatable, Sendable {
    case pending
    case accepted(frames: Int)
}

/// What sealing a file achieved. `durableFrames < acceptedFrames` is a partial file (§8.3); the crash-recovery scan
/// (RC2) owns what to do with it. Build it with `make`.
struct MediaWriteFinish: Equatable, Sendable {
    var acceptedFrames: Int64 { storedAcceptedFrames }
    var durableFrames: Int64 { storedDurableFrames }
    /// True when some accepted frames did not reach the file.
    var isPartial: Bool { storedDurableFrames < storedAcceptedFrames }
    /// How many accepted frames are missing; cannot overflow once validated.
    var missingFrames: Int64 { storedAcceptedFrames - storedDurableFrames }

    private let storedAcceptedFrames: Int64
    private let storedDurableFrames: Int64

    private init(validatedAccepted accepted: Int64, durable: Int64) {
        storedAcceptedFrames = accepted
        storedDurableFrames = durable
    }

    /// Order of checks, first failure wins: negative accepted, negative durable, durable above accepted.
    static func make(acceptedFrames: Int64, durableFrames: Int64) throws(MediaIORequestRefusal) -> MediaWriteFinish {
        guard acceptedFrames >= 0 else { throw .negativeFrames(acceptedFrames) }
        guard durableFrames >= 0 else { throw .negativeFrames(durableFrames) }
        guard durableFrames <= acceptedFrames else {
            throw .durableExceedsAccepted(durable: durableFrames, accepted: acceptedFrames)
        }
        return MediaWriteFinish(validatedAccepted: acceptedFrames, durable: durableFrames)
    }
}
