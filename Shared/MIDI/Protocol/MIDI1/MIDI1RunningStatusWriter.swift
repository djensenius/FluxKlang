/// Writes MIDI 1.0 messages and leaves out a channel status byte that repeats the previous one (#81, slice MWB1).
/// Real-time bytes do not disturb running status; System Common and SysEx end it, as `MIDI1Parser` reads it.
/// It has no clock and never resends a status by itself: call `reset()` for a new stream. Nothing calls it yet.
struct MIDI1RunningStatusWriter: Equatable, Sendable {
    /// The channel status the next message may leave out; nil when the next channel message goes out in full.
    private(set) var runningStatus: UInt8?

    init() {}

    /// The bytes to send for one semantic message. A refusal changes nothing.
    mutating func write(_ message: MIDI1Semantic) throws(MIDI1WireRefusal) -> [UInt8] {
        apply(try MIDI1Wire.bytes(message))
    }

    /// The bytes to send for one event; it shares its state with the semantic form. A refusal changes nothing.
    mutating func write(event: MIDI1Event) throws(MIDI1WireRefusal) -> [UInt8] {
        apply(try MIDI1Wire.bytes(event: event))
    }

    /// Forgets running status, so the next channel message goes out in full (a new connection or stream).
    mutating func reset() {
        runningStatus = nil
    }

    private mutating func apply(_ full: [UInt8]) -> [UInt8] {
        guard let status = full.first else { return full }
        if status >= 0xF8 { return full }
        if status >= 0xF0 {
            runningStatus = nil
            return full
        }
        let repeated = status == runningStatus
        runningStatus = status
        return repeated ? Array(full.dropFirst()) : full
    }
}
