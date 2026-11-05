//
//  MeterDisplayRefusal.swift
//  FluxKlang
//
//  Typed refusals of the truthful meter display model (#102 M1). A refused
//  factory builds nothing; a refused update leaves the model unchanged.
//

/// A floating-point meter parameter, named in `.parameterNotFinite`.
enum MeterParameter: Equatable, Sendable, CaseIterable {
    case decayRate, floor, clipThreshold
}

/// Why a meter parameter, source or update is refused.
enum MeterDisplayRefusal: Error, Equatable, Sendable {
    /// The staleness window must lie in `MeterStalenessWindow.allowedNanoseconds`.
    case stalenessWindowOutOfRange(nanoseconds: Int64)
    /// The frame-age rule must lie in `MeterClassifiedRead.allowedMaximumAgeFrames`.
    case maximumAgeFramesOutOfRange(Int64)
    /// The peak hold must lie in `MeterBallistics.allowedPeakHoldNanoseconds`.
    case peakHoldOutOfRange(nanoseconds: Int64)
    /// A floating-point parameter is NaN or infinite.
    case parameterNotFinite(MeterParameter)
    /// The decay rate must lie in `MeterBallistics.allowedDecayDecibelsPerSecond`.
    case decayRateOutOfRange(Double)
    /// The floor must lie in `MeterBallistics.allowedFloorDBFS`.
    case floorOutOfRange(Double)
    /// The clip threshold must be above the floor and at most `MeterBallistics.maximumClipThresholdDBFS`.
    case clipThresholdOutOfRange(Double, floorDBFS: Double)
    /// A tap must have `1...MeterSource.maximumChannels` channels.
    case channelCountOutOfRange(Int)
    /// An update must carry exactly one read per tap channel, in channel order.
    case channelCountMismatch(expected: Int, received: Int)
    /// The source is not a measured tap, so nothing it receives can count as signal; for example, fader travel
    /// presented as a reading.
    case readsForUnmeasuredSource(MeterUnavailableReason, count: Int)
    /// The injected host time is earlier than the previous update's.
    case clockRegressed(last: MeterInstant, now: MeterInstant)
    /// The read for `channel` (the first such channel) was classified after the update's host time; host time
    /// runs forward, so the two times cannot come from one clock.
    case classifiedAfterUpdate(channel: Int, classifiedAt: MeterInstant, now: MeterInstant)
}
