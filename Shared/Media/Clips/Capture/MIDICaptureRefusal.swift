//
//  MIDICaptureRefusal.swift
//  FluxKlang
//
//  Typed refusals of the MIDI capture log and its native UMP export (#112 CL4,
//  media-contract.md §5.2, §9.1–§9.2). A refused call returns nothing and leaves the log
//  unchanged, with one exception: a capture refused at capacity taints its stream
//  so that no later export of that stream can claim to be lossless.
//

/// Why a capture log, capture, clock observation or native UMP export is refused.
enum MIDICaptureRefusal: Error, Equatable, Sendable {
    /// The stream is not one of the log's declared streams.
    case undeclaredStream(StreamID)
    /// The log's stream list names this stream twice.
    case duplicateStream(StreamID)
    /// The log declares more than `limit` streams.
    case tooManyStreams(count: Int, limit: Int)
    /// The nominal rate is not a v1 media rate (`MediaNominalRate.isValid`).
    case invalidRate(Int)
    /// The host timebase has a zero numerator or denominator.
    case invalidTimebase
    /// The words are not one well-formed UMP packet.
    case invalidPacket(UMPRefusal)
    /// Channel voice must arrive in the port's protocol: MT 0x2 on a `midi1` port, MT 0x4 on a `midi2` port.
    case channelVoiceProtocolMismatch(messageType: UMPMessageType, port: MIDIPortProtocol)
    /// The stream's (endpoint, port) protocols changed without a `formatChange` discontinuity on it.
    case protocolChangedWithoutFormatChange(stream: StreamID)
    /// The anchor is on another sample clock than the log's.
    case foreignClock(ClockID)
    /// The generation is not the log's current sample clock generation, or a restart does not start the next one.
    case staleGeneration
    /// No anchor of the current sample clock generation has been observed since the last restart.
    case noCurrentAnchor
    /// A musical map was given without an anchored transport, was missing while one is anchored, was not built from
    /// one of the log's remembered musical anchors of the current transport generation, or is not at the current
    /// musical map revision, or has a different nominal rate.
    case musicalMapMismatch
    /// A derived musical tick would be negative.
    case negativeMusicalTicks
    /// The anchor's host ticks precede the latest `clockRestart`'s.
    case anchorPredatesRestart(restart: HostStamp)
    /// An anchor does not advance from the current anchor or agree with its generation's drift reference (§5.2–§5.3).
    case anchorDisagrees
    /// A `clockRestart` or `locate` precedes the latest restart, locate or current anchor (`cutoff`).
    case discontinuityPredatesCutoff(host: HostStamp, cutoff: HostStamp)
    /// A `clockRestart` carries no nominal rate for its new generation.
    case restartNeedsRate
    /// A nominal rate was given with a discontinuity other than `clockRestart`.
    case nominalRateWithoutRestart
    /// The discontinuity's runtime stream slot is given without a `stream:`, or its stream or clock slot is not the
    /// one the log's `RuntimePreparation` maps.
    case discontinuitySlotMismatch
    /// The `RuntimePreparation` maps no sample clock slot for the log's clock or no capture slot for a stream.
    case runtimeSlotsUnmapped
    /// A `clockRestart` or `locate` discontinuity carries no host ticks to check later captures against.
    case discontinuityNeedsHost
    /// A `formatChange` discontinuity names no stream.
    case formatChangeNeedsStream
    /// An export names no stream.
    case exportStreamsEmpty
    /// An export names this stream twice.
    case exportStreamsDuplicate(StreamID)
    /// The export's streams hold no captures.
    case exportHasNoCaptures
    /// The log has recorded no anchor for the origin's clock and generation.
    case originAnchorUnknown(clock: ClockID, generation: Generation)
    /// The stream holds a capture stamped before a restart or locate (§9.2), so nothing containing it is lossless.
    case containsUnsupportedCapture(stream: StreamID)
    /// A capture on the stream was refused at capacity, so nothing containing the stream is lossless.
    case captureRefusedAtCapacity(stream: StreamID)
    /// A bounded collection of the log holds `limit` entries already.
    case capacity(limit: Int)
    /// A derived frame, musical tick or export offset does not fit in `Int64`.
    case overflow
}
