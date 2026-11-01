import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct MIDI1Frame: Sendable {
    let bytes: [UInt8]
    let event: MIDI1Event
}

private func shortFrame(_ status: UInt8) -> MIDI1Frame {
    let data: [UInt8]
    switch status {
    case 0xC0...0xDF, 0xF1, 0xF3: data = [0]
    case 0xF4...0xF7: data = []
    default: data = [0, 127]
    }
    let event: MIDI1Event = status < 0xF0
        ? .channel(status: status, data1: data[0], data2: data.count == 2 ? data[1] : nil)
        : .systemCommon(status: status, data1: data.first, data2: data.count == 2 ? data[1] : nil)
    return MIDI1Frame(bytes: [status] + data, event: event)
}

private let shortStatuses = Array(UInt8(0x80)...0xEF) + Array(UInt8(0xF1)...0xF7)
private let realtimeFrames = [
    UInt8(0x80), 0x9F, 0xA0, 0xBF, 0xC0, 0xDF, 0xE0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7
].map(shortFrame) + [
    MIDI1Frame(bytes: [0xF0, 0, 127, 0xF7], event: .sysEx(payload: [0, 127]))
]

private struct MIDI1Trace: Sendable {
    let name: String
    let chunks: [[UInt8]]
    let events: [MIDI1Event]
}

private let recoveryTraces: [MIDI1Trace] = [
    .init(name: "stray data and EOX", chunks: [[0, 127, 0xF7, 1, 2]],
          events: [.systemCommon(status: 0xF7, data1: nil, data2: nil)]),
    .init(name: "replace partial channel", chunks: [[0x90, 60], [], [0xCF], [12, 13]],
          events: [.channel(status: 0xCF, data1: 12, data2: nil),
                   .channel(status: 0xCF, data1: 13, data2: nil)]),
    .init(name: "replace partial common", chunks: [[0xF2, 1, 0xF1], [2, 3]],
          events: [.systemCommon(status: 0xF1, data1: 2, data2: nil)]),
    .init(name: "same status replaces partial", chunks: [[0x90, 60, 0x90, 61], [62]],
          events: [.channel(status: 0x90, data1: 61, data2: 62)]),
    .init(name: "common cannot run", chunks: [[0xF2, 1], [], [2, 3, 4]],
          events: [.systemCommon(status: 0xF2, data1: 1, data2: 2)]),
    .init(name: "partial short replaced by SysEx", chunks: [[0x90, 60, 0xF0, 1, 0xF7, 2, 3]],
          events: [.sysEx(payload: [1])])
]

private let sysExTraces: [MIDI1Trace] = [
    .init(name: "empty", chunks: [[0xF0], [], [0xF7]], events: [.sysEx(payload: [])]),
    .init(name: "exact bound", chunks: [[0xF0, 0], [], [127], [0xF7]],
          events: [.sysEx(payload: [0, 127])]),
    .init(name: "overflow drops whole payload and following stray data",
          chunks: [[0xF0, 0, 127], [1, 0xF7, 2, 3]], events: []),
    .init(name: "recovery after overflow EOX", chunks: [[0xF0, 0, 127, 1, 0xF7], [0xF0, 2, 0xF7]],
          events: [.sysEx(payload: [2])]),
    .init(name: "nested fresh start", chunks: [[0xF0, 1, 0xF0], [2, 0xF7]],
          events: [.sysEx(payload: [2])]),
    .init(name: "nested after overflow", chunks: [[0xF0, 1, 2, 3, 0xF0], [4, 5, 0xF7]],
          events: [.sysEx(payload: [4, 5])]),
    .init(name: "channel interruption", chunks: [[0xF0, 1, 0x9F, 2, 3, 4, 5]],
          events: [.channel(status: 0x9F, data1: 2, data2: 3),
                   .channel(status: 0x9F, data1: 4, data2: 5)]),
    .init(name: "overflow channel interruption", chunks: [[0xF0, 1, 2, 3, 0xDF, 4, 5]],
          events: [.channel(status: 0xDF, data1: 4, data2: nil),
                   .channel(status: 0xDF, data1: 5, data2: nil)]),
    .init(name: "common interruption", chunks: [[0xF0, 1, 0xF2, 2, 3, 4, 5]],
          events: [.systemCommon(status: 0xF2, data1: 2, data2: 3)]),
    .init(name: "overflow common interruption", chunks: [[0xF0, 1, 2, 3, 0xF6, 4, 5]],
          events: [.systemCommon(status: 0xF6, data1: nil, data2: nil)]),
    .init(name: "undefined common interruption", chunks: [[0xF0, 1, 0xF4, 2, 0xF7]],
          events: [.systemCommon(status: 0xF4, data1: nil, data2: nil),
                   .systemCommon(status: 0xF7, data1: nil, data2: nil)]),
    .init(name: "all realtime during discard",
          chunks: [[0xF0, 1, 2, 3], Array(0xF8...0xFF), Array(repeating: 127, count: 256), [0xF7]],
          events: (0xF8...0xFF).map { .realTime(status: $0) })
]

private struct MIDI1SemanticCase: Sendable {
    let raw: MIDI1Event
    let expected: MIDI1Semantic?
}

private let semanticCases: [MIDI1SemanticCase] = [
    // Raw 9n/0 is retained, but normalized release velocity is 64 (RFC 6295 Appendix A.7).
    .init(raw: .channel(status: 0x90, data1: 0, data2: 0),
          expected: .noteOff(channel: 1, note: 0, velocity: 64)),
    .init(raw: .channel(status: 0x9F, data1: 127, data2: 0),
          expected: .noteOff(channel: 16, note: 127, velocity: 64)),
    .init(raw: .channel(status: 0x90, data1: 60, data2: 1),
          expected: .noteOn(channel: 1, note: 60, velocity: 1)),
    .init(raw: .channel(status: 0x9F, data1: 127, data2: 127),
          expected: .noteOn(channel: 16, note: 127, velocity: 127)),
    // Explicit 8n Note Off retains its actual release velocity, including zero.
    .init(raw: .channel(status: 0x80, data1: 0, data2: 0),
          expected: .noteOff(channel: 1, note: 0, velocity: 0)),
    .init(raw: .channel(status: 0x8F, data1: 127, data2: 127),
          expected: .noteOff(channel: 16, note: 127, velocity: 127)),
    .init(raw: .channel(status: 0xAF, data1: 60, data2: 127),
          expected: .polyphonicPressure(channel: 16, note: 60, pressure: 127)),
    .init(raw: .channel(status: 0xB0, data1: 0, data2: 0),
          expected: .controlChange(channel: 1, controller: 0, value: 0)),
    .init(raw: .channel(status: 0xBF, data1: 127, data2: 127),
          expected: .controlChange(channel: 16, controller: 127, value: 127)),
    .init(raw: .channel(status: 0xCF, data1: 127, data2: nil),
          expected: .programChange(channel: 16, program: 127)),
    .init(raw: .channel(status: 0xD0, data1: 0, data2: nil),
          expected: .channelPressure(channel: 1, pressure: 0)),
    .init(raw: .channel(status: 0xE0, data1: 0, data2: 0),
          expected: .pitchBend(channel: 1, value: 0)),
    .init(raw: .channel(status: 0xEF, data1: 0, data2: 64),
          expected: .pitchBend(channel: 16, value: 8192)),
    .init(raw: .channel(status: 0xE0, data1: 127, data2: 127),
          expected: .pitchBend(channel: 1, value: 16383)),
    .init(raw: .channel(status: 0xE0, data1: 1, data2: 2),
          expected: .pitchBend(channel: 1, value: 257)),
    .init(raw: .systemCommon(status: 0xF1, data1: 127, data2: nil),
          expected: .systemCommon(status: 0xF1, data1: 127, data2: nil)),
    .init(raw: .systemCommon(status: 0xF2, data1: 0, data2: 127),
          expected: .systemCommon(status: 0xF2, data1: 0, data2: 127)),
    .init(raw: .systemCommon(status: 0xF3, data1: 0, data2: nil),
          expected: .systemCommon(status: 0xF3, data1: 0, data2: nil)),
    .init(raw: .sysEx(payload: []), expected: .sysEx(payload: [])),
    .init(raw: .sysEx(payload: [0, 127]), expected: .sysEx(payload: [0, 127]))
] + (UInt8(0xF4)...0xF7).map {
    .init(raw: .systemCommon(status: $0, data1: nil, data2: nil),
          expected: .systemCommon(status: $0, data1: nil, data2: nil))
} + (UInt8(0xF8)...0xFF).map {
    .init(raw: .realTime(status: $0), expected: .realTime(status: $0))
} + [
    MIDI1Event.channel(status: 0, data1: 1, data2: 2),
    .channel(status: 0xF0, data1: 1, data2: 2),
    .channel(status: 0xFF, data1: 1, data2: 2),
    .channel(status: 0x90, data1: 128, data2: 0),
    .channel(status: 0x90, data1: 0, data2: 255),
    .channel(status: 0x90, data1: 0, data2: nil),
    .channel(status: 0xC0, data1: 0, data2: 0),
    .channel(status: 0xDF, data1: 255, data2: nil),
    .systemCommon(status: 0x90, data1: 0, data2: 1),
    .systemCommon(status: 0xF0, data1: nil, data2: nil),
    .systemCommon(status: 0xF1, data1: nil, data2: nil),
    .systemCommon(status: 0xF1, data1: 0, data2: 0),
    .systemCommon(status: 0xF2, data1: 0, data2: nil),
    .systemCommon(status: 0xF2, data1: 128, data2: 0),
    .systemCommon(status: 0xF2, data1: 0, data2: 128),
    .systemCommon(status: 0xF3, data1: 255, data2: nil),
    .systemCommon(status: 0xF4, data1: 0, data2: nil),
    .systemCommon(status: 0xF7, data1: nil, data2: 0),
    .systemCommon(status: 0xF8, data1: nil, data2: nil),
    .realTime(status: 0xF7),
    .sysEx(payload: [0xF0, 0xF7]),
    .sysEx(payload: [0xF8])
].map { .init(raw: $0, expected: nil) }

struct MIDIProtocolTests {
    @Test(arguments: shortStatuses)
    fileprivate func shortLengthsAndChunkContinuation(status: UInt8) throws {
        let frame = shortFrame(status)
        let data = Array(frame.bytes.dropFirst())
        let bytes = frame.bytes + data + data
        var expected = [MIDI1Event?](repeating: nil, count: bytes.count)
        expected[frame.bytes.count - 1] = frame.event
        if status < 0xF0 {
            expected[frame.bytes.count + data.count - 1] = frame.event
            expected[bytes.count - 1] = frame.event
        }
        for split in 0...bytes.count {
            var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 2))
            let chunks = [Array(bytes.prefix(split)), [], Array(bytes.dropFirst(split))]
            var actual: [MIDI1Event?] = []
            for chunk in chunks {
                for byte in chunk { actual.append(parser.consume(byte)) }
            }
            #expect(actual == expected)
        }
    }

    @Test(arguments: UInt8(0xF8)...0xFF, realtimeFrames)
    fileprivate func realtimeIsTransparent(status: UInt8, frame: MIDI1Frame) throws {
        for position in 0...frame.bytes.count {
            var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 2))
            var bytes = frame.bytes
            bytes.insert(status, at: position)
            var expected = [MIDI1Event?](repeating: nil, count: frame.bytes.count)
            expected[frame.bytes.count - 1] = frame.event
            expected.insert(.realTime(status: status), at: position)
            #expect(bytes.map { parser.consume($0) } == expected)
        }
    }

    @Test(arguments: UInt8(0xF0)...0xFF)
    fileprivate func cancellationReplacementAndReset(status: UInt8) throws {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 2))
        #expect(feed([0x90, 1, 2, 3], into: &parser) == [.channel(status: 0x90, data1: 1, data2: 2)])
        if status >= 0xF8 {
            #expect(feed([status, 4, 5, 6], into: &parser) == [
                .realTime(status: status), .channel(status: 0x90, data1: 3, data2: 4),
                .channel(status: 0x90, data1: 5, data2: 6)
            ])
        } else {
            let frame = status == 0xF0
                ? MIDI1Frame(bytes: [0xF0, 0xF7], event: .sysEx(payload: []))
                : shortFrame(status)
            #expect(feed(frame.bytes + [7, 8], into: &parser) == [frame.event])
        }
        for trace in recoveryTraces { try check(trace) }
        let resetPrefixes: [[UInt8]] = [
            [], [0x90], [0x90, 1], [0x90, 1, 2], [0xCF, 1], [0xF2, 1],
            [0xF0], [0xF0, 1, 2], [0xF0, 1, 2, 3]
        ]
        for prefix in resetPrefixes {
            parser.reset()
            _ = feed(prefix, into: &parser)
            parser.reset()
            parser.reset()
            #expect(parser.maximumSysExPayloadBytes == 2)
            #expect(feed([1, 2], into: &parser).isEmpty)
            #expect(parser.consume(0xF7) == .systemCommon(status: 0xF7, data1: nil, data2: nil))
            #expect(feed([0xF0, 1, 2, 0xF7], into: &parser) == [.sysEx(payload: [1, 2])])
            #expect(feed([0xF0, 1, 2, 3, 0xF7], into: &parser).isEmpty)
            #expect(feed([0xCF, 127], into: &parser) == [.channel(status: 0xCF, data1: 127, data2: nil)])
        }
    }

    @Test(arguments: sysExTraces)
    fileprivate func boundedSysExAndRecovery(trace: MIDI1Trace) throws {
        try check(trace)
        for invalid in [Int.min, -1, 0] {
            #expect(MIDI1Parser(maximumSysExPayloadBytes: invalid) == nil)
        }
        // An enormous explicit bound is accepted without reserving that much storage.
        var large = try #require(MIDI1Parser(maximumSysExPayloadBytes: Int.max))
        #expect(feed([0xF0, 1, 0xF7], into: &large) == [.sysEx(payload: [1])])
        var smallest = try #require(MIDI1Parser(maximumSysExPayloadBytes: 1))
        #expect(feed([0xF0, 127, 0xF7], into: &smallest) == [.sysEx(payload: [127])])
        #expect(feed([0xF0, 127, 0, 0xF7], into: &smallest).isEmpty)
        // Copies must not share mutable framing/payload state.
        var original = try #require(MIDI1Parser(maximumSysExPayloadBytes: 2))
        #expect(feed([0xF0, 1], into: &original).isEmpty)
        var copy = original
        #expect(feed([2, 0xF7], into: &copy) == [.sysEx(payload: [1, 2])])
        #expect(original.consume(0xF7) == .sysEx(payload: [1]))
    }

    @Test(arguments: semanticCases)
    fileprivate func rawAndNormalizedSemantics(sample: MIDI1SemanticCase) throws {
        #expect(sample.raw.semantic == sample.expected)
        guard sample.expected != nil else { return }
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 2))
        var bytes: [UInt8]
        switch sample.raw {
        case let .channel(status, data1, data2): bytes = [status, data1] + [data2].compactMap { $0 }
        case let .systemCommon(status, data1, data2): bytes = [status] + [data1, data2].compactMap { $0 }
        case let .realTime(status): bytes = [status]
        case let .sysEx(payload): bytes = [0xF0] + payload + [0xF7]
        }
        #expect(feed(bytes, into: &parser) == [sample.raw])
        if case .channel = sample.raw {
            bytes.removeFirst()
            #expect(feed(bytes, into: &parser) == [sample.raw])
        }
        // Conversion never rewrites the raw 9n origin (or any other raw data).
        #expect(sample.raw.semantic == sample.expected)
    }

    private func feed(_ bytes: [UInt8], into parser: inout MIDI1Parser) -> [MIDI1Event] {
        bytes.compactMap { parser.consume($0) }
    }

    private func check(_ trace: MIDI1Trace) throws {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 2))
        var events: [MIDI1Event] = []
        for chunk in trace.chunks { events += feed(chunk, into: &parser) }
        #expect(events == trace.events, "\(trace.name)")
    }
}
