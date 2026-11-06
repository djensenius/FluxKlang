import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// SplitMix64, deterministic for a seed.
private struct StreamPropertyGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// One generated step: a message received, or a poll from the caller's timer.
private enum StreamPropertyStep {
    case message(UMPMIDI1ChannelVoice)
    case poll
}

/// Draws timeouts, gaps and messages that select parameters and hold, complete, abandon and time out Data Entry
/// values on two groups × two channels. Half the messages reuse the previous message's group and channel, so a CC 38
/// often follows its CC 6.
private struct StreamPropertyScript {
    var random: StreamPropertyGenerator
    var last: (group: UInt8, channel: UInt8) = (0, 0)

    init(seed: UInt64) {
        random = StreamPropertyGenerator(state: seed)
    }

    /// RPN 0/6 on group 0 and NRPN 1/2 on group 1, both channels; sent at the start of every run.
    static func selections() throws -> [UMPMIDI1ChannelVoice] {
        var voices: [UMPMIDI1ChannelVoice] = []
        for group: UInt8 in [0, 1] {
            for channel: UInt8 in [0, 1] {
                let pairs: [(UInt8, UInt8)] = group == 0 ? [(101, 0), (100, 6)] : [(99, 1), (98, 2)]
                for (controller, value) in pairs {
                    voices.append(try UMPMIDI1ChannelVoice(
                        group: UMPGroup(group), event: .channel(status: 0xB0 | channel, data1: controller,
                                                                data2: value)))
                }
            }
        }
        return voices
    }

    mutating func pick<T>(_ values: [T]) -> T { values[Int(random.next() % UInt64(values.count))] }

    mutating func timeout() throws -> UMPTranslationStreamTimeout {
        let allowed = UMPTranslationStreamTimeout.allowedNanoseconds
        switch random.next() % 4 {
        case 0: return try .make(nanoseconds: allowed.lowerBound)
        case 1: return try .make(nanoseconds: allowed.upperBound)
        case 2: return .standard
        default: return try .make(nanoseconds: UInt64.random(in: allowed, using: &random))
        }
    }

    /// A gap that often lands on the timeout or one nanosecond either side of it.
    mutating func gap(_ timeout: UInt64) -> UInt64 {
        switch random.next() % 8 {
        case 0: return 0
        case 1: return timeout - 1
        case 2: return timeout
        case 3: return timeout + 1
        case 4, 5: return random.next() % timeout
        default: return random.next() % (3 * timeout)
        }
    }

    /// The selections (no gap), then `count` generated steps with their gaps.
    mutating func plan(_ count: Int, timeout: UMPTranslationStreamTimeout) throws
        -> [(gap: UInt64, step: StreamPropertyStep)] {
        var plan = try Self.selections().map { (gap: UInt64(0), step: StreamPropertyStep.message($0)) }
        for _ in 0..<count { plan.append((gap(timeout.nanoseconds), try step())) }
        return plan
    }

    mutating func step() throws -> StreamPropertyStep {
        if random.next() % 2 == 0 { last = (UInt8(random.next() % 2), UInt8(random.next() % 2)) }
        let group = try UMPGroup(last.group)
        let channel = last.channel
        let value = UInt8(random.next() % 128)
        let event: MIDI1Event
        switch random.next() % 20 {
        case 0..<3:
            return .poll
        case 3..<8:
            event = .channel(status: 0xB0 | channel, data1: 6, data2: value)
        case 8..<12:
            event = .channel(status: 0xB0 | channel, data1: 38, data2: value)
        case 12..<15:
            event = .channel(status: 0xB0 | channel, data1: pick([101, 100, 99, 98]), data2: pick([0, 1, 6, 127]))
        case 15:
            event = .channel(status: 0xB0 | channel, data1: pick([96, 121, 0, 32, 7]), data2: value)
        case 16:
            event = .channel(status: 0x90 | channel, data1: value, data2: pick([0, 100]))
        case 17:
            event = .channel(status: 0xC0 | channel, data1: value, data2: nil)
        default:
            event = .channel(status: 0xE0 | channel, data1: value, data2: 64)
        }
        return .message(try UMPMIDI1ChannelVoice(group: group, event: event))
    }
}

@Suite("MIDI 1→2 translation stream property")
struct UMPTranslationStreamPropertyTests {
    static let seeds: [UInt64] = [0x0362, 0x5EED_0362, 0xC0FF_EE00_0362]
    static let runs = 120
    static let steps = 60

    /// Whether `voice` is the CC 38 on `held`'s own group and channel, the one that would have completed it.
    static func completes(_ voice: UMPMIDI1ChannelVoice, _ held: UMPMIDI2ChannelVoice) -> Bool {
        guard case let .channel(status, data1, _) = voice.event else { return false }
        return status & 0xF0 == 0xB0 && data1 == 38 && voice.group == held.group && status & 0x0F == held.channel.value
    }

    /// The stream sends what the bare translator sends with `flushAll()` inserted wherever a CC 6 has been held for
    /// the timeout. Against a translator that is never flushed early, nothing is lost, duplicated or reordered: the
    /// only extra message is the LSB-0 value sent before a late CC 38.
    @Test(arguments: seeds)
    func outputIsTheTranslatorsOwnWithIdleFlushesInsertedAtTheirDeadlines(seed: UInt64) throws {
        var script = StreamPropertyScript(seed: seed)
        var totalIdle = 0
        var totalLate = 0
        for run in 0..<Self.runs {
            let timeout = try script.timeout()
            var stream = UMPTranslationStream(timeout: timeout)
            var reference = UMPMIDI1ToMIDI2Translator()
            var untimed = UMPMIDI1ToMIDI2Translator()
            var heldSince: UInt64?
            var idle = 0
            var time = script.random.next() % (1 << 40)
            var sent: [UMPMIDI2ChannelVoice] = []
            var untimedSent: [UMPMIDI2ChannelVoice] = []
            // Where in `sent` the last idle-flushed CC 6 is, until the next message; and the ones a late CC 38 met.
            var pending: (index: Int, voice: UMPMIDI2ChannelVoice)?
            var lateLSB0: Set<Int> = []
            for (gap, step) in try script.plan(Self.steps, timeout: timeout) {
                time += gap
                var expected: [UMPMIDI2ChannelVoice] = []
                if let since = heldSince, time - since >= timeout.nanoseconds {
                    expected = reference.flushAll()
                    #expect(expected.count == 1, "run \(run)")
                    if let voice = expected.first { pending = (sent.count, voice) }
                    idle += 1
                    heldSince = nil
                }
                switch step {
                case .poll:
                    let actual = try stream.poll(at: time)
                    #expect(actual == expected, "run \(run) at \(time)")
                    sent += actual
                case let .message(voice):
                    if let flushed = pending, Self.completes(voice, flushed.voice) { lateLSB0.insert(flushed.index) }
                    pending = nil
                    let output = try reference.translate(voice)
                    heldSince = reference.heldDataEntry == nil ? nil : time
                    let actual = try stream.receive(voice, at: time)
                    #expect(actual == UMPTranslationOutput(messages: expected + output.messages, losses: output.losses),
                            "run \(run) at \(time)")
                    sent += actual.messages
                    untimedSent += try untimed.translate(voice).messages
                }
                #expect(stream.deadline == heldSince.map { $0 + timeout.nanoseconds }, "run \(run)")
                #expect(stream.translator == reference, "run \(run)")
                #expect(stream.idleFlushes == idle, "run \(run)")
                #expect(stream.lastAcceptedTime == time, "run \(run)")
            }
            let tail = stream.endOfStream()
            #expect(tail == reference.flushAll(), "run \(run)")
            #expect(stream.endOfStreamFlushes == tail.count, "run \(run)")
            sent += tail
            untimedSent += untimed.flushAll()
            let kept = sent.indices.filter { !lateLSB0.contains($0) }.map { sent[$0] }
            #expect(kept == untimedSent, "run \(run)")
            #expect(stream.losses == untimed.losses, "run \(run)")
            #expect(stream.losses == reference.losses, "run \(run)")
            totalIdle += idle
            totalLate += lateLSB0.count
        }
        // The script reaches both an idle flush and a late CC 38 many times.
        #expect(totalIdle >= 300)
        #expect(totalLate >= 30)
    }

    /// Polling changes only when a held CC 6 is sent, never what is sent or in which order: with or without polls in
    /// between, the same messages at the same times produce the same output once each stream ends.
    @Test(arguments: seeds)
    func pollingChangesOnlyWhenAHeldDataEntryIsSent(seed: UInt64) throws {
        var script = StreamPropertyScript(seed: seed ^ 0xFFFF)
        var totalPolledFlushes = 0
        for run in 0..<Self.runs {
            let timeout = try script.timeout()
            var polled = UMPTranslationStream(timeout: timeout)
            var unpolled = UMPTranslationStream(timeout: timeout)
            var time = script.random.next() % (1 << 40)
            var polledSent: [UMPMIDI2ChannelVoice] = []
            var unpolledSent: [UMPMIDI2ChannelVoice] = []
            for (gap, step) in try script.plan(Self.steps, timeout: timeout) {
                time += gap
                switch step {
                case .poll:
                    let deadline = polled.deadline
                    let flushed = try polled.poll(at: time)
                    #expect(flushed.isEmpty == (deadline.map { time < $0 } ?? true), "run \(run) at \(time)")
                    totalPolledFlushes += flushed.count
                    polledSent += flushed
                case let .message(voice):
                    polledSent += try polled.receive(voice, at: time).messages
                    unpolledSent += try unpolled.receive(voice, at: time).messages
                }
            }
            polledSent += polled.endOfStream()
            unpolledSent += unpolled.endOfStream()
            #expect(polledSent == unpolledSent, "run \(run)")
            #expect(polled.idleFlushes + polled.endOfStreamFlushes
                == unpolled.idleFlushes + unpolled.endOfStreamFlushes, "run \(run)")
            #expect(polled.idleFlushes >= unpolled.idleFlushes, "run \(run)")
            #expect(polled.losses == unpolled.losses, "run \(run)")
            #expect(polled.translator == unpolled.translator, "run \(run)")
        }
        #expect(totalPolledFlushes >= 50)
    }
}
