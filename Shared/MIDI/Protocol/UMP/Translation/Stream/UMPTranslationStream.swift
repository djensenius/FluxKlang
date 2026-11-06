/// One input stream's MIDI 1.0 → MIDI 2.0 translation, with the held Data Entry flushes that
/// `UMPMIDI1ToMIDI2Translator` leaves to the I/O layer (#362): after an idle timeout, at the end of the stream, and at
/// teardown or reset.
///
/// The translator holds a CC 6 (Data Entry MSB) until the next message, because a CC 38 (LSB) may complete it. A lone
/// CC 6 (an MPE Configuration Message, a semitone-only Pitch Bend Sensitivity) would stay held until the next message
/// arrives. This stream sends it:
///
/// - Idle: when the CC 6 has been held for `timeout`, at `deadline` (hold time + timeout). The caller arms one timer
///   for `deadline` and calls `poll(at:)`, which sends the CC 6 at or after the deadline (not one nanosecond earlier).
///   A message received at or after the deadline first sends the held CC 6 and then its own translation, in that
///   order. Both count as idle flushes.
/// - End of stream: `endOfStream()`, at the end of one segment of a logical stream (for example one SMF track that
///   the next segment continues); the translator state carries into the next segment.
/// - Teardown or reset: `reset()`, or `reset(group:channel:)` for one group and channel.
///
/// The translator sends a held CC 6 before every message except the CC 38 that completes it, so a CC 6 still held
/// after `receive` is always the one just received: its hold time is that call's time.
///
/// A late CC 38 (one that arrives after its CC 6 was flushed) is translated as the translator translates any further
/// CC 38: the Data Entry MSB survives a flush, so the controller is sent again with the last MSB and the new LSB, and
/// no loss is declared. The receiver sees the value with LSB 0, then the completed value.
///
/// Time is supplied by the caller in monotonic nanoseconds (the I/O layer converts host ticks); this type reads no
/// clock and arms no timer. `receive` and `poll` refuse a time earlier than the last one this stream accepted; equal
/// times are accepted. `endOfStream()` and `reset()` clear that baseline, so the next segment or stream may start at
/// any time.
/// The deadline never wraps: a CC 6 whose deadline would pass `UInt64.max` is refused (`deadlineOverflow`). Refusing
/// drops a valid CC 6, whereas capping the deadline at `UInt64.max` would flush it at most one timeout early; both
/// happen only with a broken clock.
///
/// Telemetry is cumulative for the life of the value and survives `reset()`: `losses` (every loss the translator
/// declared, including those of translators that `reset()` replaced), `idleFlushes`, `endOfStreamFlushes` and
/// `resetFlushes`.
///
/// Not real-time safe: it copies its state and allocates its output, like the translator. Call it on the control or
/// I/O thread only, never on the audio render thread.
///
/// A refused call returns nothing and changes nothing.
struct UMPTranslationStream: Equatable, Sendable {
    /// How long a CC 6 is held before an idle flush.
    let timeout: UMPTranslationStreamTimeout
    /// The wrapped translator (read-only; for example `translator.heldDataEntry`).
    private(set) var translator = UMPMIDI1ToMIDI2Translator()
    /// When the held CC 6 is sent by `poll(at:)`; nil when nothing is held.
    private(set) var deadline: UInt64?
    /// The last time `receive` or `poll` accepted; nil for a new stream and after `endOfStream()` or `reset()`.
    private(set) var lastAcceptedTime: UInt64?
    /// Every loss the translator declared through this stream, across `reset()`.
    private(set) var losses = UMPTranslationLossCounts()
    /// Held CC 6s sent because their deadline was reached (by `poll(at:)` or `receive(_:at:)`).
    private(set) var idleFlushes = 0
    /// Held CC 6s sent by `endOfStream()`.
    private(set) var endOfStreamFlushes = 0
    /// Held CC 6s sent by `reset()` or `reset(group:channel:)`.
    private(set) var resetFlushes = 0

    init(timeout: UMPTranslationStreamTimeout = .standard) {
        self.timeout = timeout
    }

    /// Translates one message received at `time`. If a held CC 6 has reached its deadline, it is sent first.
    /// A live caller whose times may step back (CoreMIDI timestamp 0 meaning "now", or jitter) may pass
    /// `max(time, lastAcceptedTime ?? time)` rather than drop the message on `timeWentBackward`.
    mutating func receive(
        _ voice: UMPMIDI1ChannelVoice, at time: UInt64
    ) throws(UMPTranslationStreamRefusal) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
        try admit(time)
        var next = self
        let idle = next.flushIfIdle(at: time)
        let output: UMPTranslationOutput<UMPMIDI2ChannelVoice>
        do throws(UMPRefusal) {
            output = try next.translator.translate(voice)
        } catch {
            throw .translation(error)
        }
        if next.translator.heldDataEntry == nil {
            next.deadline = nil
        } else {
            let (deadline, overflow) = time.addingReportingOverflow(timeout.nanoseconds)
            guard !overflow else { throw .deadlineOverflow(heldAt: time, timeoutNanoseconds: timeout.nanoseconds) }
            next.deadline = deadline
        }
        next.losses.record(output.losses)
        next.lastAcceptedTime = time
        self = next
        return UMPTranslationOutput(messages: idle + output.messages, losses: output.losses)
    }

    /// Sends the held CC 6 if `time` has reached its deadline; otherwise returns `[]`.
    mutating func poll(at time: UInt64) throws(UMPTranslationStreamRefusal) -> [UMPMIDI2ChannelVoice] {
        try admit(time)
        lastAcceptedTime = time
        return flushIfIdle(at: time)
    }

    /// Ends a segment: sends any held CC 6 and clears the time baseline, so the next segment may start at any time.
    /// The translator's bank, parameter selection and Data Entry MSB are kept, so a late CC 38 at the start of the
    /// next segment sends the controller again with the kept MSB. Use it between consecutive segments of one logical
    /// stream, not between independent streams: those need their own stream or `reset()` (for example each track of
    /// a Format 1 SMF, whose tracks are concurrent).
    mutating func endOfStream() -> [UMPMIDI2ChannelVoice] {
        let flushed = translator.flushAll()
        endOfStreamFlushes += flushed.count
        deadline = nil
        lastAcceptedTime = nil
        return flushed
    }

    /// Teardown or reset: sends any held CC 6, then starts again as a new stream with the same timeout (a fresh
    /// translator, no time baseline). The cumulative telemetry is kept. The caller forwards the returned messages
    /// before anything translated after this call.
    mutating func reset() -> [UMPMIDI2ChannelVoice] {
        let flushed = translator.flushAll()
        resetFlushes += flushed.count
        translator = UMPMIDI1ToMIDI2Translator()
        deadline = nil
        lastAcceptedTime = nil
        return flushed
    }

    /// Forgets one group and channel (`UMPMIDI1ToMIDI2Translator.reset(group:channel:)`), sending a CC 6 held on it.
    /// The time baseline is kept. The caller forwards the returned messages before anything translated after this
    /// call.
    mutating func reset(group: UMPGroup, channel: UMPChannel) -> [UMPMIDI2ChannelVoice] {
        let flushed = translator.reset(group: group, channel: channel)
        resetFlushes += flushed.count
        if translator.heldDataEntry == nil { deadline = nil }
        return flushed
    }

    private func admit(_ time: UInt64) throws(UMPTranslationStreamRefusal) {
        if let previous = lastAcceptedTime, time < previous {
            throw .timeWentBackward(previous: previous, got: time)
        }
    }

    private mutating func flushIfIdle(at time: UInt64) -> [UMPMIDI2ChannelVoice] {
        guard let deadline, time >= deadline else { return [] }
        self.deadline = nil
        let flushed = translator.flushAll()
        idleFlushes += flushed.count
        return flushed
    }
}
