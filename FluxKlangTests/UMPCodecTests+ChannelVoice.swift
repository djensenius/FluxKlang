import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct UMPMT4Vector {
    let message: UMPMIDI2Message
    let first: UInt32
    let second: UInt32

    init(_ first: UInt32, _ second: UInt32, _ message: UMPMIDI2Message) {
        self.message = message
        self.first = first
        self.second = second
    }
}

@Suite("UMP channel voice", .productionAccessAudit)
struct UMPChannelVoiceTests {
    static func seven(_ value: UInt8) throws -> UMPSevenBit { try UMPSevenBit(value) }

    static func mt4(_ first: UInt32, _ second: UInt32) throws -> UMPMIDI2ChannelVoice {
        try UMPMIDI2ChannelVoice(decoding: UMPPacket(words: [first, second]))
    }

    static func mt2(_ word: UInt32) throws -> UMPMIDI1ChannelVoice {
        try UMPMIDI1ChannelVoice(decoding: UMPPacket(words: [word]))
    }

    /// One vector per MT4 status (group 3, channel 5), with its exact words.
    private static func vectors() throws -> [UMPMT4Vector] {
        let bank = UMPBankSelect(msb: try seven(0x7F), lsb: try seven(0x01))
        return [
            UMPMT4Vector(0x4305_3CF1, 0x1234_5678,
                         .registeredPerNoteController(note: try seven(60), index: 0xF1, value: 0x1234_5678)),
            UMPMT4Vector(0x4315_3D02, 0x89AB_CDEF,
                         .assignablePerNoteController(note: try seven(61), index: 0x02, value: 0x89AB_CDEF)),
            UMPMT4Vector(0x4325_7F01, 0xFEDC_BA98,
                         .registeredController(bank: try seven(0x7F), index: try seven(1), value: 0xFEDC_BA98)),
            UMPMT4Vector(0x4335_107F, 1,
                         .assignableController(bank: try seven(0x10), index: try seven(0x7F), value: 1)),
            UMPMT4Vector(0x4345_0006, 0xFFFF_FFFF,
                         .relativeRegisteredController(bank: try seven(0), index: try seven(6), delta: -1)),
            UMPMT4Vector(0x4355_0102, 0xFFFF_EDCC,
                         .relativeAssignableController(bank: try seven(1), index: try seven(2), delta: -0x1234)),
            UMPMT4Vector(0x4365_3C00, 0x8040_0000, .perNotePitchBend(note: try seven(60), value: 0x8040_0000)),
            UMPMT4Vector(0x4385_3C03, 0x1234_5678,
                         .noteOff(note: try seven(60), velocity: 0x1234, attributeType: 3, attribute: 0x5678)),
            UMPMT4Vector(0x4395_7F02, 0xC924_0123,
                         .noteOn(note: try seven(127), velocity: 0xC924, attributeType: 2, attribute: 0x0123)),
            UMPMT4Vector(0x43A5_0000, 0xDEAD_BEEF, .polyPressure(note: try seven(0), value: 0xDEAD_BEEF)),
            UMPMT4Vector(0x43B5_4A00, 0x9A3C_5E71, .controlChange(index: try seven(74), value: 0x9A3C_5E71)),
            UMPMT4Vector(0x43C5_0001, 0x1200_7F01, .programChange(program: try seven(0x12), bank: bank)),
            UMPMT4Vector(0x43C5_0000, 0x7F00_0000, .programChange(program: try seven(0x7F), bank: nil)),
            UMPMT4Vector(0x43D5_0000, 0x8000_0000, .channelPressure(value: 0x8000_0000)),
            UMPMT4Vector(0x43E5_0000, 0xFFFF_FFFF, .pitchBend(value: 0xFFFF_FFFF)),
            UMPMT4Vector(0x43F5_3C02, 0, .perNoteManagement(note: try seven(60), detach: true, reset: false)),
            UMPMT4Vector(0x43F5_3D01, 0, .perNoteManagement(note: try seven(61), detach: false, reset: true)),
            UMPMT4Vector(0x43F5_3E03, 0, .perNoteManagement(note: try seven(62), detach: true, reset: true))
        ]
    }

    // MARK: MT4

    @Test func everyMT4StatusEncodesAndDecodesExactly() throws {
        let vectors = try Self.vectors()
        let statuses = Set(vectors.map { UInt8(($0.first >> 20) & 0x0F) })
        #expect(statuses == Set(UInt8(0)...15).subtracting([7]))
        for vector in vectors {
            let (message, first, second) = (vector.message, vector.first, vector.second)
            let voice = UMPMIDI2ChannelVoice(group: try UMPGroup(3), channel: try UMPChannel(5), message: message)
            #expect(voice.packet.words == [first, second], "\(message)")
            let decoded = try Self.mt4(first, second)
            #expect(decoded == voice)
            #expect(decoded.packet.words == [first, second])
        }
    }

    @Test func mt4KeepsEveryGroupAndChannelNibble() throws {
        for vector in try Self.vectors() {
            let (message, first, second) = (vector.message, vector.first, vector.second)
            for group in UInt32(0)...15 {
                for channel in UInt32(0)...15 {
                    let word = (first & 0xF0F0_FFFF) | group << 24 | channel << 16
                    let decoded = try Self.mt4(word, second)
                    #expect(decoded.group.value == UInt8(group) && decoded.channel.value == UInt8(channel))
                    #expect(decoded.message == message && decoded.packet.words == [word, second])
                }
            }
        }
    }

    @Test func mt4NoteOnVelocityZeroStaysNoteOn() throws {
        let decoded = try Self.mt4(0x4090_3C00, 0x0000_0000)
        #expect(decoded.message == .noteOn(note: try Self.seven(60), velocity: 0, attributeType: 0, attribute: 0))
        #expect(decoded.packet.words == [0x4090_3C00, 0x0000_0000])
        let built = UMPMIDI2ChannelVoice(group: try UMPGroup(0), channel: try UMPChannel(0),
                                         message: .noteOn(note: try Self.seven(60), velocity: 0, attributeType: 0,
                                                          attribute: 0))
        #expect(built.packet.words == [0x4090_3C00, 0])
    }

    @Test func mt4ValuesAreNotRescaledOrReinterpreted() throws {
        // Example 09 (OS-upscaled MIDI 1) and 10 (genuine MIDI 2) words decode to their raw values either way.
        let upscaled = try Self.mt4(0x4090_3C00, 0xC924_0000)
        #expect(upscaled.message == .noteOn(note: try Self.seven(60), velocity: 0xC924, attributeType: 0, attribute: 0))
        let genuine = try Self.mt4(0x4190_4000, 0x0100_0000)
        #expect(genuine.message == .noteOn(note: try Self.seven(64), velocity: 0x0100, attributeType: 0, attribute: 0))
        #expect(genuine.group.value == 1)
        let control = try Self.mt4(0x40B0_0700, 0x8000_0000)
        #expect(control.message == .controlChange(index: try Self.seven(7), value: 0x8000_0000))
    }

    @Test func mt4ReservedStatusIsRefused() {
        #expect(throws: UMPRefusal.reservedStatus(mt: .midi2ChannelVoice, status: 7)) {
            try Self.mt4(0x4070_0000, 0)
        }
    }

    @Test func mt4ReservedBitsAreRefused() {
        let cases: [(UInt32, UInt32)] = [
            (0x4000_8000, 0), (0x4010_8000, 0), (0x4020_8000, 0), (0x4020_0080, 0), (0x4030_0080, 0),
            (0x4040_8000, 0), (0x4050_0080, 0), (0x4060_3C01, 0), (0x4060_BC00, 0), (0x4080_BC00, 0),
            (0x4090_BC00, 0), (0x40A0_3C01, 0), (0x40A0_8000, 0), (0x40B0_8000, 0), (0x40B0_0001, 0),
            (0x40C0_0100, 0), (0x40C0_0002, 0), (0x40C0_0080, 0), (0x40C0_0000, 0x8000_0000),
            (0x40C0_0000, 0x0001_0000), (0x40C0_0000, 0x0000_0001), (0x40C0_0000, 0x0000_0100),
            (0x40C0_0001, 0x0000_8000), (0x40C0_0001, 0x0000_0080), (0x40C0_0001, 0x0080_0000),
            (0x40D0_0100, 0), (0x40D0_0001, 0), (0x40E0_0100, 0), (0x40E0_0001, 0),
            (0x40F0_3C04, 0), (0x40F0_3C80, 0), (0x40F0_BC00, 0), (0x40F0_3C00, 1), (0x40F0_3C00, 0x8000_0000)
        ]
        for (first, second) in cases {
            let status = UInt8((first >> 20) & 0x0F)
            #expect(throws: UMPRefusal.reservedBitsSet(mt: .midi2ChannelVoice, status: status), "\(first) \(second)") {
                try Self.mt4(first, second)
            }
        }
    }

    @Test func mt4FullWidthFieldsAreAccepted() throws {
        let perNote = try Self.mt4(0x4000_7FFF, 0)
        #expect(perNote.message == .registeredPerNoteController(note: try Self.seven(127), index: 0xFF, value: 0))
        let attribute = try Self.mt4(0x4080_7FFF, 0xFFFF_FFFF)
        #expect(attribute.message == .noteOff(note: try Self.seven(127), velocity: 0xFFFF, attributeType: 0xFF,
                                              attribute: 0xFFFF))
        let relative = try Self.mt4(0x4040_7F7F, 0x8000_0000)
        #expect(relative.message == .relativeRegisteredController(bank: try Self.seven(127), index: try Self.seven(127),
                                                                  delta: .min))
        let bank = try Self.mt4(0x40C0_0001, 0x7F00_7F7F)
        #expect(bank.message == .programChange(program: try Self.seven(127),
                                               bank: UMPBankSelect(msb: try Self.seven(127), lsb: try Self.seven(127))))
    }

    @Test func mt4RefusesOtherMessageTypes() throws {
        #expect(throws: UMPRefusal.wrongMessageType(expected: .midi2ChannelVoice, actual: .midi1ChannelVoice)) {
            try UMPMIDI2ChannelVoice(decoding: UMPPacket(words: [0x2090_3C64]))
        }
        #expect(throws: UMPRefusal.wrongMessageType(expected: .midi2ChannelVoice, actual: .data64)) {
            try UMPMIDI2ChannelVoice(decoding: UMPPacket(words: [0x3090_3C64, 0]))
        }
    }

    // MARK: MT2

    @Test func mt2DecodingAgreesWithMIDI1Semantic() throws {
        let data: [UInt8] = [0x00, 0x01, 0x3C, 0x40, 0x7F, 0x80, 0xFF]
        var group: UInt32 = 0
        for status in UInt8(0x80)...0xEF {
            let single = (0xC0...0xDF).contains(status)
            for data1 in data {
                for data2 in data {
                    group = (group + 1) & 0x0F
                    let word = 0x2000_0000 | group << 24 | UInt32(status) << 16 | UInt32(data1) << 8 | UInt32(data2)
                    try Self.expectMT2(word, group: group, single: single)
                }
            }
        }
    }

    static func expectMT2(_ word: UInt32, group: UInt32, single: Bool) throws {
        let status = UInt8(truncatingIfNeeded: word >> 16)
        let data1 = UInt8(truncatingIfNeeded: word >> 8)
        let data2 = UInt8(truncatingIfNeeded: word)
        if single && data2 != 0 {
            #expect(throws: UMPRefusal.reservedBitsSet(mt: .midi1ChannelVoice, status: status)) { try mt2(word) }
            return
        }
        let event = MIDI1Event.channel(status: status, data1: data1, data2: single ? nil : data2)
        guard let semantic = event.semantic else {
            #expect(throws: UMPRefusal.invalidMIDI1Message(status: status, data1: data1, data2: single ? nil : data2)) {
                try mt2(word)
            }
            return
        }
        let decoded = try mt2(word)
        #expect(decoded.semantic == semantic && decoded.event == event && decoded.group.value == UInt8(group))
        #expect(decoded.packet.words == [word])
    }

    @Test func mt2StatusesOutsideChannelVoiceAreRefused() {
        for status in Array(UInt8(0)...0x7F) + Array(UInt8(0xF0)...0xFF) {
            #expect(throws: UMPRefusal.reservedStatus(mt: .midi1ChannelVoice, status: status)) {
                try Self.mt2(0x2000_0000 | UInt32(status) << 16)
            }
        }
    }

    @Test func mt2NoteOnVelocityZeroFollowsMIDI1Semantic() throws {
        let decoded = try Self.mt2(0x2090_3C00)
        #expect(decoded.semantic == .noteOff(channel: 1, note: 60, velocity: 64))
        #expect(decoded.event == .channel(status: 0x90, data1: 60, data2: 0))
        #expect(decoded.packet.words == [0x2090_3C00])
    }

    @Test func mt2EncodesContractExamples() throws {
        let keys = try UMPMIDI1ChannelVoice(group: UMPGroup(0), semantic: .noteOn(channel: 1, note: 60, velocity: 100))
        #expect(keys.packet.words == [0x2090_3C64])
        let legacy = try UMPMIDI1ChannelVoice(group: UMPGroup(1), semantic: .noteOn(channel: 1, note: 60,
                                                                                     velocity: 100))
        #expect(legacy.packet.words == [0x2190_3C64])
        let off = try UMPMIDI1ChannelVoice(group: UMPGroup(0), semantic: .noteOff(channel: 1, note: 60, velocity: 0))
        #expect(off.packet.words == [0x2080_3C00])
    }

    @Test func mt2SemanticRoundTripsOnEveryChannelAndGroup() throws {
        for channel in UInt8(1)...16 {
            let messages: [MIDI1Semantic] = [
                .noteOff(channel: channel, note: 1, velocity: 2), .noteOn(channel: channel, note: 127, velocity: 1),
                .polyphonicPressure(channel: channel, note: 3, pressure: 4),
                .controlChange(channel: channel, controller: 74, value: 127),
                .programChange(channel: channel, program: 9), .channelPressure(channel: channel, pressure: 99),
                .pitchBend(channel: channel, value: 0x3FFF), .pitchBend(channel: channel, value: 0x2001)
            ]
            for message in messages {
                let group = try UMPGroup(16 - channel)
                let voice = try UMPMIDI1ChannelVoice(group: group, semantic: message)
                let decoded = try UMPMIDI1ChannelVoice(decoding: voice.packet)
                #expect(decoded == voice && decoded.semantic == message && decoded.group == group)
                #expect((voice.packet.words[0] >> 16) & 0x0F == UInt32(channel - 1))
            }
        }
    }

    @Test func mt2PitchBendBytes() throws {
        let centre = try UMPMIDI1ChannelVoice(group: UMPGroup(0), semantic: .pitchBend(channel: 2, value: 0x2000))
        #expect(centre.packet.words == [0x20E1_0040])
        let top = try UMPMIDI1ChannelVoice(group: UMPGroup(0), semantic: .pitchBend(channel: 1, value: 0x3FFF))
        #expect(top.packet.words == [0x20E0_7F7F])
    }

    @Test func mt2PitchBendAboveFourteenBitsIsRefusedNotWrapped() throws {
        for value: UInt16 in [0x4000, 0x7FFF, 0x8000, 0xBFFF, 0xFFFF] {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .fourteenBit, value: Int(value)), "\(value)") {
                try UMPMIDI1ChannelVoice(group: UMPGroup(0), semantic: .pitchBend(channel: 1, value: value))
            }
        }
    }

    @Test func mt2DataBytesAboveSevenBitsAreRefusedNotWrapped() throws {
        let group = try UMPGroup(0)
        let wide: [MIDI1Semantic] = [
            .noteOff(channel: 1, note: 0x80, velocity: 0), .noteOn(channel: 1, note: 60, velocity: 0x80),
            .polyphonicPressure(channel: 1, note: 60, pressure: 0xFF),
            .controlChange(channel: 1, controller: 0x80, value: 0),
            .controlChange(channel: 1, controller: 0, value: 0x80),
            .programChange(channel: 1, program: 0x80),
            .channelPressure(channel: 1, pressure: 0xC0)
        ]
        for message in wide {
            #expect(throws: UMPRefusal.self, "\(message)") { try UMPMIDI1ChannelVoice(group: group, semantic: message) }
        }
    }

    @Test func mt2NoteOnVelocityZeroKeepsRawBytesAndMIDI1Meaning() throws {
        let voice = try UMPMIDI1ChannelVoice(group: UMPGroup(2), semantic: .noteOn(channel: 3, note: 60, velocity: 0))
        #expect(voice.packet.words == [0x2292_3C00])
        #expect(voice.event == .channel(status: 0x92, data1: 60, data2: 0))
        #expect(voice.semantic == .noteOff(channel: 3, note: 60, velocity: 64))
        let decoded = try UMPMIDI1ChannelVoice(decoding: voice.packet)
        #expect(decoded == voice && decoded.packet.words == [0x2292_3C00])
    }

    @Test func mt2BuildersRefuseInvalidInput() throws {
        let group = try UMPGroup(0)
        for channel: UInt8 in [0, 17] {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .channel, value: Int(channel))) {
                try UMPMIDI1ChannelVoice(group: group, semantic: .programChange(channel: channel, program: 0))
            }
        }
        #expect(try UMPMIDI1ChannelVoice(group: group, semantic: .programChange(channel: 16, program: 0)).packet
            .words == [0x20CF_0000])
        for message: MIDI1Semantic in [.realTime(status: 0xF8), .sysEx(payload: [1]),
                                       .systemCommon(status: 0xF6, data1: nil, data2: nil)] {
            #expect(throws: UMPRefusal.notChannelVoice) { try UMPMIDI1ChannelVoice(group: group, semantic: message) }
        }
        #expect(throws: UMPRefusal.notChannelVoice) {
            try UMPMIDI1ChannelVoice(group: group, event: .realTime(status: 0xF8))
        }
        #expect(throws: UMPRefusal.invalidMIDI1Message(status: 0x90, data1: 0x80, data2: 1)) {
            try UMPMIDI1ChannelVoice(group: group, event: .channel(status: 0x90, data1: 0x80, data2: 1))
        }
        #expect(throws: UMPRefusal.invalidMIDI1Message(status: 0xC0, data1: 1, data2: 1)) {
            try UMPMIDI1ChannelVoice(group: group, event: .channel(status: 0xC0, data1: 1, data2: 1))
        }
    }

    @Test func mt2RefusesOtherMessageTypes() {
        #expect(throws: UMPRefusal.wrongMessageType(expected: .midi1ChannelVoice, actual: .midi2ChannelVoice)) {
            try UMPMIDI1ChannelVoice(decoding: UMPPacket(words: [0x4090_3C00, 0]))
        }
        #expect(throws: UMPRefusal.wrongMessageType(expected: .midi1ChannelVoice, actual: .system)) {
            try Self.mt2(0x1090_3C64)
        }
    }
}
