//
//  MIDICaptureRefusal.swift
//  FluxKlang
//
//  Typed refusals of the MIDI capture log and its native UMP export (#112 CL4,
//  media-contract.md §9.1–§9.2). A refused call returns nothing and leaves the log
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
    /// The generation is not the log's current sample clock generation, or a restart does not start a new one.
    case staleGeneration
    /// No anchor of the current sample clock generation has been observed since the last restart.
    case noCurrentAnchor
    /// A musical map was given without an anchored transport, was missing while one is anchored, or is not on the
    /// log's clock, current sample generation and current transport.
    case musicalMapMismatch
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
