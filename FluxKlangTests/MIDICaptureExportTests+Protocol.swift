import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// One row of the media-contract §9.1 table.
private struct MIDICaptureProtocolRow: Sendable, CustomTestStringConvertible {
    let endpoint: MIDIEndpointProtocol
    let port: MIDIPortProtocol
    let words: [UInt32]
    let translatedByOS: Bool
    let effective: MIDIPortProtocol
    let verified: Bool

    var testDescription: String { "\(endpoint.rawValue)/\(port.rawValue)" }
}

private let protocolTable = [
    MIDICaptureProtocolRow(endpoint: .midi1, port: .midi1, words: [0x2090_3C64], translatedByOS: false,
                           effective: .midi1, verified: true),
    MIDICaptureProtocolRow(endpoint: .midi1, port: .midi2, words: [0x4090_3C00, 0xC924_0000], translatedByOS: true,
                           effective: .midi1, verified: true),
    MIDICaptureProtocolRow(endpoint: .midi2, port: .midi2, words: [0x4190_3C03, 0xC925_1E00], translatedByOS: false,
                           effective: .midi2, verified: true),
    MIDICaptureProtocolRow(endpoint: .midi2, port: .midi1, words: [0x2190_3C64], translatedByOS: true,
                           effective: .midi1, verified: true),
    MIDICaptureProtocolRow(endpoint: .unknown, port: .midi2, words: [0x4190_3C00, 0xC924_0000], translatedByOS: true,
                           effective: .midi1, verified: false)
]

#if os(macOS)
@Suite("MIDI capture protocol", .productionAccessAudit)
#else
@Suite("MIDI capture protocol")
#endif
struct MIDICaptureProtocolTests {
    typealias Fixture = MIDICaptureFixture

    static func anchoredLog(_ streams: [StreamID] = [MIDICaptureFixture.keysA]) throws -> MIDICaptureLog {
        var log = try Fixture.log(streams)
        try log.observe(anchor: Fixture.anchor(1, frame: 0, host: 2_400_000_000))
        return log
    }

    @Test(arguments: protocolTable)
    fileprivate func tableRow(_ row: MIDICaptureProtocolRow) throws {
        let stamp = try MIDIProtocolStamp.classify(UMPPacket(words: row.words), endpoint: row.endpoint, port: row.port)
        #expect(stamp.endpoint == row.endpoint && stamp.port == row.port)
        #expect(stamp.translatedByOS == row.translatedByOS)
        #expect(stamp.effective == row.effective)
        #expect(stamp.verified == row.verified)
        var log = try Self.anchoredLog()
        let outcome = try Fixture.capture(&log, Fixture.keysA, row.words, host: 2_412_000_000, endpoint: row.endpoint,
                                          port: row.port)
        let record = try #require(log.records.last)
        #expect(outcome == .recorded(record))
        #expect(log.records.map(\.protocolStamp) == [stamp])
    }

    @Test func example10StampsMatchTheContract() throws {
        let log = try Fixture.example10()
        let stamps = log.records.map(\.protocolStamp)
        #expect(stamps.map(\.effective) == [.midi2, .midi2, .midi2, .midi2, .midi2, .midi2, .midi1, .midi1, .midi2])
        #expect(stamps.map(\.translatedByOS) == [false, false, false, false, false, false, true, true, false])
        #expect(stamps.map(\.verified) == [true, true, true, true, true, true, true, false, true])
        #expect(log.records.map(\.sample.frame) == [24_005, 36_000, 48_000, 60_000, 72_000, 84_000, 96_000, 108_000,
                                                    120_000])
        #expect(log.records.map(\.musicalTicks) == [15_363, 23_040, 30_720, 38_400, 46_080, 53_760, 61_440, 69_120,
                                                    76_800])
    }

    @Test func channelVoiceMustArriveInThePortsProtocol() throws {
        var log = try Self.anchoredLog()
        let before = log
        for endpoint in MIDIEndpointProtocol.allCases {
            #expect(Fixture.refusal {
                try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_412_000_000, endpoint: endpoint,
                                    port: .midi2)
            } == .channelVoiceProtocolMismatch(messageType: .midi1ChannelVoice, port: .midi2))
            #expect(Fixture.refusal {
                try Fixture.capture(&log, Fixture.keysA, [0x4090_3C00, 0xC924_0000], host: 2_412_000_000,
                                    endpoint: endpoint, port: .midi1)
            } == .channelVoiceProtocolMismatch(messageType: .midi2ChannelVoice, port: .midi1))
        }
        #expect(log == before)
    }

    @Test func otherMessageTypesAreAcceptedOnEitherPort() throws {
        let utility = try UMPPacket(words: [0x0020_1F40])
        let stream = try UMPPacket(words: [0xF000_0000, 0, 0, 0])
        for packet in [utility, stream] {
            for endpoint in MIDIEndpointProtocol.allCases {
                for port in MIDIPortProtocol.allCases {
                    let stamp = try MIDIProtocolStamp.classify(packet, endpoint: endpoint, port: port)
                    #expect(stamp.effective == (endpoint == .midi2 && port == .midi2 ? .midi2 : .midi1))
                    #expect(stamp.verified == (endpoint != .unknown))
                    #expect(stamp.translatedByOS == ((endpoint == .midi2 ? .midi2 : .midi1) != port))
                }
            }
        }
        var log = try Self.anchoredLog([Fixture.keysA, Fixture.keysB])
        try Fixture.capture(&log, Fixture.keysA, [0x0020_1F40], host: 2_412_000_000, port: .midi1)
        try Fixture.capture(&log, Fixture.keysB, [0xF000_0000, 0, 0, 0], host: 2_412_000_000, port: .midi2)
        #expect(log.records.map(\.packet.words) == [[0x0020_1F40], [0xF000_0000, 0, 0, 0]])
    }

    @Test func invalidPacketsAreRefused() throws {
        var log = try Self.anchoredLog()
        let before = log
        #expect(Fixture.refusal { try Fixture.capture(&log, Fixture.keysA, [], host: 2_412_000_000) }
            == .invalidPacket(.emptyPacket))
        #expect(Fixture.refusal { try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64, 0], host: 2_412_000_000) }
            == .invalidPacket(.wrongWordCount(mt: .midi1ChannelVoice, have: 2, need: 1)))
        #expect(Fixture.refusal { try Fixture.capture(&log, Fixture.synth, [0x2090_3C64], host: 2_412_000_000) }
            == .undeclaredStream(Fixture.synth))
        #expect(log == before)
    }

    @Test func protocolChangeNeedsFormatChangeOnThatStream() throws {
        var log = try Self.anchoredLog([Fixture.keysA, Fixture.keysB])
        try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_412_000_000)
        try Fixture.capture(&log, Fixture.keysB, [0x2090_3C64], host: 2_412_000_000)
        let before = log
        let midi2 = [UInt32(0x4090_3C00), 0xC924_0000]
        #expect(Fixture.refusal {
            try Fixture.capture(&log, Fixture.keysA, midi2, host: 2_424_000_000, endpoint: .midi2, port: .midi2)
        } == .protocolChangedWithoutFormatChange(stream: Fixture.keysA))
        #expect(Fixture.refusal {
            try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_424_000_000, endpoint: .unknown)
        } == .protocolChangedWithoutFormatChange(stream: Fixture.keysA))
        #expect(log == before)
        // A formatChange on another stream does not re-pin this one.
        try log.observe(Fixture.discontinuity(.formatChange, host: nil), stream: Fixture.keysB)
        #expect(Fixture.refusal {
            try Fixture.capture(&log, Fixture.keysA, midi2, host: 2_424_000_000, endpoint: .midi2, port: .midi2)
        } == .protocolChangedWithoutFormatChange(stream: Fixture.keysA))
        try log.observe(Fixture.discontinuity(.formatChange, host: nil), stream: Fixture.keysA)
        try Fixture.capture(&log, Fixture.keysA, midi2, host: 2_424_000_000, endpoint: .midi2, port: .midi2)
        // The new pair is pinned now, until the next formatChange.
        #expect(Fixture.refusal { try Fixture.capture(&log, Fixture.keysA, [0x2090_3C64], host: 2_436_000_000) }
            == .protocolChangedWithoutFormatChange(stream: Fixture.keysA))
        #expect(log.records.last?.protocolStamp.effective == .midi2)
    }

    @Test func formatChangeNamesADeclaredStream() throws {
        var log = try Self.anchoredLog()
        let before = log
        #expect(Fixture.refusal { try log.observe(Fixture.discontinuity(.formatChange, host: nil), stream: nil) }
            == .formatChangeNeedsStream)
        #expect(Fixture.refusal {
            try log.observe(Fixture.discontinuity(.formatChange, host: nil), stream: Fixture.synth)
        } == .undeclaredStream(Fixture.synth))
        #expect(log == before)
    }

    @Test func streamDeclarationsAreBounded() throws {
        let streams = try (0..<MIDICaptureLog.maximumStreams).map { try StreamID("str.cl4-\($0)") }
        #expect(try Fixture.log(streams).streams == streams)
        let extra = try StreamID("str.cl4-extra")
        #expect(Fixture.refusal { try Fixture.log(streams + [extra]) }
            == .tooManyStreams(count: 65, limit: 64))
        #expect(Fixture.refusal { try Fixture.log([Fixture.keysA, Fixture.keysB, Fixture.keysA]) }
            == .duplicateStream(Fixture.keysA))
        #expect(Fixture.refusal {
            try MIDICaptureLog(streams: [], clock: Fixture.clock, timebase: Fixture.timebase, nominalRate: 47_999)
        } == .invalidRate(47_999))
        #expect(Fixture.refusal { try Fixture.log([], timebase: HostTimebase(numer: 0, denom: 1)) } == .invalidTimebase)
        #expect(Fixture.refusal { try Fixture.log([], timebase: HostTimebase(numer: 1, denom: 0)) } == .invalidTimebase)
    }
}
