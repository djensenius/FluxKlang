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
/// deadline over all streams, or cancels it when no stream holds a CC 6. The armed callback polls every stream that
/// holds a CC 6 at the clock's time.
///
/// `sink` is the driver's only output. Every call and every timer poll hands its non-empty output to `sink` with the
/// stream's ID (so streams that share a group and channel stay apart), synchronously on the actor, so `sink` receives
/// batches in the order the driver produced them. `sink` must not block or re-enter the driver.
///
/// Control or I/O isolation only: the driver allocates and is an actor, so calling it from the audio render thread
/// is not allowed, and a synchronous call from a render closure does not compile.
///
/// Refusals are the stream's own (`UMPTranslationStreamRefusal`). A MIDI 1 event that is not a channel voice, System
/// Common or System Real Time message has no stream path: `receive` refuses `.sysEx` with
/// `.translation(.notChannelVoice)`.
///
/// `stop()` is final: it cancels the timer and resets every stream, and after it nothing is sent to `sink`, even by a
/// timer callback already queued.
actor UMPTranslationStreamDriver {
    private let clock: any UMPTranslationStreamClock
    private let timer: any UMPTranslationStreamTimer
    private let timeout: UMPTranslationStreamTimeout
    private let sink: @Sendable (UMPTranslationStreamID, [UMPTranslationStreamItem]) -> Void
    private var streams: [UMPTranslationStreamID: UMPTranslationStream] = [:]
    private var armedAt: UInt64?
    /// Per stream, the time of a timer poll that moved the stream's time baseline forward. An event stamped before
    /// it is admitted at it, because the timer's poll may run late; the event's stamp still decides its timing. Set
    /// only by a poll of a stream that holds a CC 6 and has a baseline.
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
        sink: @escaping @Sendable (UMPTranslationStreamID, [UMPTranslationStreamItem]) -> Void
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

    /// Translates one MIDI 1 event stamped `rawTime` (monotonic nanoseconds) on stream `id` and sends the output to
    /// `sink` as one batch, if non-empty. A held CC 6 whose deadline the stamp has reached comes before the event's own
    /// output. On a refusal nothing is sent and no state changes.
    ///
    /// A time earlier than the stream's last accepted time is refused (`timeWentBackward`), not clamped, with one
    /// exception: the timer's poll may run late and move the baseline past an event's stamp, so an event stamped
    /// before the baseline that such a poll set is admitted at that baseline, provided its stamp is not earlier than
    /// the last event this stream accepted. An event earlier than that one is passed through unchanged and refused.
    /// Every other refusal propagates unchanged.
    ///
    /// The admission time only orders the stream's calls. The stamp alone decides timing: a held CC 6 is sent first
    /// when the stamp is at or after its deadline, and a CC 6 the event holds gets the deadline stamp + timeout. So a
    /// CC 6 and a CC 38 stamped within the timeout of it still pair when both arrive after a late poll, and a CC 6
    /// whose deadline the CC 38's stamp has reached is sent alone first. Such a deadline may already be at or before
    /// the admission time: the timer is then armed for that past deadline, and its poll sends the CC 6 unless an
    /// event stamped before the deadline arrives first. Either way the CC 6 reaches `sink` after this call's batch.
    func receive(
        _ event: MIDI1Event, group: UMPGroup, stream id: UMPTranslationStreamID, atNanoseconds rawTime: UInt64
    ) throws(UMPTranslationStreamRefusal) {
        guard !stopped else { return }
        var admission = rawTime
        if let baseline = pollBaselines[id], rawTime >= lastReceived[id] ?? 0 { admission = max(rawTime, baseline) }
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
            items = try stream.receive(voice, at: rawTime, admittedAt: admission).messages
                .map(UMPTranslationStreamItem.voice)
        case .systemCommon, .realTime:
            let system: UMPSystemCommonRealTime
            do throws(UMPRefusal) {
                system = try UMPSystemCommonRealTime(group: group, event: event)
            } catch {
                throw .translation(error)
            }
            items = try stream.receive(system: system, at: rawTime, admittedAt: admission)
        case .sysEx:
            throw .translation(.notChannelVoice)
        }
        streams[id] = stream
        lastReceived[id] = rawTime
        send(id, items)
        rearm()
    }

    /// Ends a segment of stream `id`: sends the held CC 6, if any, to `sink`.
    func endOfStream(_ id: UMPTranslationStreamID) {
        guard var stream = streams[id] else { return }
        let flushed = stream.endOfStream()
        streams[id] = stream
        pollBaselines[id] = nil
        lastReceived[id] = nil
        send(id, flushed.map(UMPTranslationStreamItem.voice))
        rearm()
    }

    /// Resets stream `id` as a new stream: sends the held CC 6, if any, to `sink`.
    func reset(_ id: UMPTranslationStreamID) {
        guard var stream = streams[id] else { return }
        let flushed = stream.reset()
        streams[id] = stream
        pollBaselines[id] = nil
        lastReceived[id] = nil
        send(id, flushed.map(UMPTranslationStreamItem.voice))
        rearm()
    }

    /// Teardown: cancels the timer, resets every stream and sends what they held to `sink`, one batch per stream that
    /// held something, in `UMPTranslationStreamID` order. The driver sends nothing after this.
    func stop() {
        stopped = true
        timer.cancel()
        armedAt = nil
        for id in streams.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let messages = streams[id]?.reset() else { continue }
            send(id, messages.map(UMPTranslationStreamItem.voice))
        }
        streams = [:]
        pollBaselines = [:]
        lastReceived = [:]
    }

    /// What the armed timer callback runs. Polls every stream that holds a CC 6 at the clock's time, never earlier
    /// than the stream's last accepted time (backward clock jitter), sends each non-empty flush to `sink` with its
    /// stream's ID, and re-arms for the next deadline. A stream that holds nothing is not polled, and no baseline is
    /// recorded for a stream without a last accepted time, so a fire for another stream cannot restore a baseline
    /// that `endOfStream` or `reset` cleared.
    private func fire() {
        guard !stopped else { return }
        armedAt = nil
        let now = clock.nowNanoseconds()
        for id in streams.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var stream = streams[id], stream.deadline != nil else { continue }
            do throws(UMPTranslationStreamRefusal) {
                let before = stream.lastAcceptedTime
                let polledAt = max(now, before ?? now)
                let flushed = try stream.poll(at: polledAt)
                streams[id] = stream
                if let before, polledAt > before { pollBaselines[id] = polledAt }
                send(id, flushed.map(UMPTranslationStreamItem.voice))
            } catch {
                pollRefusals += 1
            }
        }
        rearm()
    }

    /// Arms the timer for the earliest deadline, or cancels it when none is held. Does nothing when the timer is
    /// already armed for that deadline. A deadline the clock has already passed (a CC 6 admitted after its stamp's
    /// deadline) is armed as any other, so the timer fires at once.
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
            await self?.fire()
        }
    }

    private func send(_ id: UMPTranslationStreamID, _ items: [UMPTranslationStreamItem]) {
        if !items.isEmpty { sink(id, items) }
    }
}
