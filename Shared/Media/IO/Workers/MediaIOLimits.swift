//
//  MediaIOLimits.swift
//  FluxKlang
//
//  The bounds of the media I/O worker contract (#109 IO2, media-contract.md
//  §8.2, §8.3). Every literal of the slice lives here and nowhere else.
//

/// The bounds of the reader and writer worker contract. Every bound is accepted at N and refused at N + 1.
enum MediaIOLimits {
    /// The most frames one read or write request covers; equal to the largest prefetch block.
    static let maximumRequestFrames = PrefetchPlan.blockFramesRange.upperBound
    /// The most steps a scripted reader or writer holds.
    static let maximumScriptSteps = 256
    /// The most requests a scripted fake records; later calls are counted, not recorded.
    static let maximumRecordedRequests = 256
    /// The most reads the fill pump keeps in flight.
    static let maximumInFlight = 1
    /// The most consecutive `pending` polls of one read before the pump treats it as a stall.
    static let maximumPendingPolls = 8
    /// The most consecutive failures of one range the pump retries; the next one latches the fault.
    static let maximumConsecutiveRetries = 3
}
