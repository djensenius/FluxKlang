/// Names one input stream of a `UMPTranslationStreamDriver`.
struct UMPTranslationStreamID: Hashable, Sendable {
    let rawValue: UInt32

    init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// Drives one `UMPTranslationStream` per input stream from a single deadline timer (#83, #362).
///
/// The streams read no clock; this driver supplies the time. After every change it arms the timer for the earliest
/// deadline over all streams, or cancels it when no stream holds a CC 6. When the timer fires, `fire()` polls every
/// stream at the clock's time and hands what it flushes to `sink`: a timer-driven flush has no caller to return to.
/// Every other call returns its output to its caller.
///
/// Control or I/O isolation only: the driver allocates and is an actor, so calling it from the audio render thread
/// is not allowed, and a synchronous call from a render closure does not compile.
///
/// Refusals are the stream's own (`UMPTranslationStreamRefusal`). A MIDI 1 event that is not a channel voice, System
/// Common or System Real Time message has no stream path: `receive` refuses `.sysEx` with
/// `.translation(.notChannelVoice)`.
///
/// `stop()` is final: it cancels the timer, resets every stream, and after it `fire()` sends nothing and `receive`
/// returns `[]`.
actor UMPTranslationStreamDriver {
    private let clock: any UMPTranslationStreamClock
    private let timer: any UMPTranslationStreamTimer
    private let timeout: UMPTranslationStreamTimeout
    private let sink: @Sendable ([UMPMIDI2ChannelVoice]) -> Void
    private var streams: [UMPTranslationStreamID: UMPTranslationStream] = [:]
    private var armedAt: UInt64?
    /// Per stream, the time of a timer poll that moved the stream's time baseline forward. An event stamped before
    /// it is clamped to it, because the timer's poll may run late.
    private var pollBaselines: [UMPTranslationStreamID: UInt64] = [:]
    /// Per stream, the raw time of the last event the stream accepted. The poll baseline never excuses an event
    /// stamped before it.
    private var lastReceived: [UMPTranslationStreamID: UInt64] = [:]
    private var stopped = false
    /// Timer-driven polls a stream refused. The clamp in `fire()` keeps it at 0 whatever the clock does.
    private(set) var pollRefusals = 0

    init(
        clock: any UMPTranslationStreamClock,
        timer: any UMPTranslationStreamTimer,
        timeout: UMPTranslationStreamTimeout = .standard,
        sink: @escaping @Sendable ([UMPMIDI2ChannelVoice]) -> Void
    ) {
        self.clock = clock
        self.timer = timer
        self.timeout = timeout
        self.sink = sink
    }

    /// The stream for `id`, for telemetry and tests; nil before its first message.
    func stream(_ id: UMPTranslationStreamID) -> UMPTranslationStream? {
        streams[id]
    }

    /// Translates one MIDI 1 event received at `time` (monotonic nanoseconds) on stream `id`. A held CC 6 whose
    /// deadline `time` has reached is returned before the event's own output.
    ///
    /// A time earlier than the stream's last accepted time is refused (`timeWentBackward`), not clamped, with one
    /// exception: the timer's poll may run late and move the baseline past an event's stamp, so a time before the
    /// baseline that such a poll set is raised to it, provided it is not earlier than the last event this stream
    /// accepted. An event earlier than that one is passed through unchanged and refused. Every other refusal
    /// propagates unchanged.
    func receive(
        _ event: MIDI1Event, group: UMPGroup, stream id: UMPTranslationStreamID, atNanoseconds rawTime: UInt64
    ) throws(UMPTranslationStreamRefusal) -> [UMPTranslationStreamItem] {
        guard !stopped else { return [] }
        var time = rawTime
        if let baseline = pollBaselines[id], rawTime >= lastReceived[id] ?? 0 { time = max(rawTime, baseline) }
        var stream = streams[id] ?? UMPTranslationStream(timeout: timeout)
        let items: [UMPTranslationStreamItem]
        switch event {
        case .channel:
            let voice: UMPMIDI1ChannelVoice
            do throws(UMPRefusal) {
                voice = try UMPMIDI1ChannelVoice(group: group, event: event)
            } catch {
                throw .translation(error)
            }
            items = try stream.receive(voice, at: time).messages.map(UMPTranslationStreamItem.voice)
        case .systemCommon, .realTime:
            let system: UMPSystemCommonRealTime
            do throws(UMPRefusal) {
                system = try UMPSystemCommonRealTime(group: group, event: event)
            } catch {
                throw .translation(error)
            }
            items = try stream.receive(system: system, at: time)
        case .sysEx:
            throw .translation(.notChannelVoice)
        }
        streams[id] = stream
        lastReceived[id] = rawTime
        rearm()
        return items
    }

    /// Ends a segment of stream `id`: returns the held CC 6, if any.
    func endOfStream(_ id: UMPTranslationStreamID) -> [UMPMIDI2ChannelVoice] {
        guard var stream = streams[id] else { return [] }
        let flushed = stream.endOfStream()
        streams[id] = stream
        pollBaselines[id] = nil
        lastReceived[id] = nil
        rearm()
        return flushed
    }

    /// Resets stream `id` as a new stream: returns the held CC 6, if any.
    func reset(_ id: UMPTranslationStreamID) -> [UMPMIDI2ChannelVoice] {
        guard var stream = streams[id] else { return [] }
        let flushed = stream.reset()
        streams[id] = stream
        pollBaselines[id] = nil
        lastReceived[id] = nil
        rearm()
        return flushed
    }

    /// Teardown: cancels the timer, resets every stream (in `UMPTranslationStreamID` order) and returns what they
    /// held. The driver sends nothing after this.
    func stop() -> [UMPMIDI2ChannelVoice] {
        stopped = true
        timer.cancel()
        armedAt = nil
        var flushed: [UMPMIDI2ChannelVoice] = []
        for id in streams.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            flushed += streams[id]?.reset() ?? []
        }
        streams = [:]
        pollBaselines = [:]
        lastReceived = [:]
        return flushed
    }

    /// What the timer calls. Polls every stream at the clock's time, never earlier than the stream's last accepted
    /// time (backward clock jitter), sends non-empty flushes to `sink`, and re-arms for the next deadline.
    func fire() {
        guard !stopped else { return }
        armedAt = nil
        let now = clock.nowNanoseconds()
        for id in streams.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var stream = streams[id] else { continue }
            do throws(UMPTranslationStreamRefusal) {
                let before = stream.lastAcceptedTime
                let polledAt = max(now, before ?? now)
                let flushed = try stream.poll(at: polledAt)
                streams[id] = stream
                if before.map({ polledAt > $0 }) ?? true { pollBaselines[id] = polledAt }
                if !flushed.isEmpty { sink(flushed) }
            } catch {
                pollRefusals += 1
            }
        }
        rearm()
    }

    /// Arms the timer for the earliest deadline, or cancels it when none is held. Does nothing when the timer is
    /// already armed for that deadline.
    private func rearm() {
        guard !stopped else { return }
        guard let target = streams.values.compactMap(\.deadline).min() else {
            if armedAt != nil {
                timer.cancel()
                armedAt = nil
            }
            return
        }
        guard armedAt != target else { return }
        armedAt = target
        timer.arm(atNanoseconds: target) { [weak self] in
            Task { await self?.fire() }
        }
    }
}
