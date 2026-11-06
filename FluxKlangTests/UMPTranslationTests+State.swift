import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI 1↔2 translation state")
struct UMPTranslationStateTests {
    static func cc(_ channel: UInt8, _ controller: UInt8, _ value: UInt8, group: UInt8 = 0) throws
        -> UMPMIDI1ChannelVoice {
        try UMPMIDI1ChannelVoice(group: UMPGroup(group), event: .channel(status: 0xB0 | channel, data1: controller,
                                                                           data2: value))
    }

    static func program(_ channel: UInt8, _ program: UInt8, group: UInt8 = 0) throws -> UMPMIDI1ChannelVoice {
        try UMPMIDI1ChannelVoice(group: UMPGroup(group), event: .channel(status: 0xC0 | channel, data1: program,
                                                                           data2: nil))
    }

    static func mt4(_ group: UInt8, _ channel: UInt8, _ message: UMPMIDI2Message) throws -> UMPMIDI2ChannelVoice {
        UMPMIDI2ChannelVoice(group: try UMPGroup(group), channel: try UMPChannel(channel), message: message)
    }

    static func seven(_ value: UInt8) throws -> UMPSevenBit { try UMPSevenBit(value) }

    static func bank(_ msb: UInt8, _ lsb: UInt8) throws -> UMPBankSelect {
        UMPBankSelect(msb: try seven(msb), lsb: try seven(lsb))
    }

    static func data(_ fourteenBit: UInt32) throws -> UInt32 {
        try UMPScaling.scaleUp(fourteenBit, fromBits: 14, toBits: 32)
    }

    /// Translates `voices` up, returning each call's output.
    static func up(_ voices: [UMPMIDI1ChannelVoice], with translator: inout UMPMIDI1ToMIDI2Translator) throws
        -> [UMPTranslationOutput<UMPMIDI2ChannelVoice>] {
        var outputs: [UMPTranslationOutput<UMPMIDI2ChannelVoice>] = []
        for voice in voices { outputs.append(try translator.translate(voice)) }
        return outputs
    }

    /// MIDI 1 → 2 → 1 through fresh translators; returns the MIDI 1.0 words and the total declared losses.
    static func roundTrip(_ voices: [UMPMIDI1ChannelVoice]) throws -> (words: [UInt32], losses: Int) {
        var upward = UMPMIDI1ToMIDI2Translator()
        var downward = UMPMIDI2ToMIDI1Translator()
        var words: [UInt32] = []
        for output in try Self.up(voices, with: &upward) {
            for message in output.messages { words += try downward.translate(message).messages.map(\.packet.words[0]) }
        }
        return (words, upward.losses.total + downward.losses.total)
    }

    @Test func bankSelectAndProgramChangeAssembleIntoOneMIDI2ProgramChange() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        let outputs = try Self.up([Self.cc(2, 0, 5), Self.cc(2, 32, 9), Self.program(2, 42), Self.program(2, 43)],
                                  with: &upward)
        #expect(outputs[0] == UMPTranslationOutput(messages: [], losses: []))
        #expect(outputs[1] == UMPTranslationOutput(messages: [], losses: []))
        #expect(outputs[2].messages
            == [try Self.mt4(0, 2, .programChange(program: Self.seven(42), bank: Self.bank(5, 9)))])
        // The bank persists, as in MIDI 1.0.
        #expect(outputs[3].messages
            == [try Self.mt4(0, 2, .programChange(program: Self.seven(43), bank: Self.bank(5, 9)))])
        #expect(outputs[2].messages[0].packet.words == [0x40C2_0001, 0x2A00_0509])
        #expect(upward.losses.total == 0)
    }

    @Test func programChangeWithoutBankHasBankValidClear() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        let output = try upward.translate(Self.program(0, 7))
        #expect(output.messages == [try Self.mt4(0, 0, .programChange(program: Self.seven(7), bank: nil))])
        #expect(output.losses.isEmpty)
    }

    @Test func halfABankSelectSendsBankValidClearWithADeclaredLoss() throws {
        for half: UInt8 in [0, 32] {
            var upward = UMPMIDI1ToMIDI2Translator()
            let outputs = try Self.up([Self.cc(1, half, 3), Self.program(1, 7)], with: &upward)
            #expect(outputs[1].messages == [try Self.mt4(0, 1, .programChange(program: Self.seven(7), bank: nil))])
            #expect(outputs[1].losses == [UMPTranslationLoss(reason: .incompleteBankSelect, group: try UMPGroup(0),
                                                             channel: try UMPChannel(1))], "CC \(half)")
            #expect(upward.losses.count(.incompleteBankSelect) == 1)
        }
    }

    @Test func downSendsBankSelectOnlyWhenTheBankChanges() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        func events(_ program: UInt8, _ bank: UMPBankSelect?) throws -> [MIDI1Event] {
            try downward.translate(Self.mt4(0, 3, .programChange(program: Self.seven(program), bank: bank))).messages
                .map(\.event)
        }
        #expect(try events(1, nil) == [.channel(status: 0xC3, data1: 1, data2: nil)])
        #expect(try events(2, Self.bank(5, 9)) == [.channel(status: 0xB3, data1: 0, data2: 5),
                                                   .channel(status: 0xB3, data1: 32, data2: 9),
                                                   .channel(status: 0xC3, data1: 2, data2: nil)])
        #expect(try events(3, Self.bank(5, 9)) == [.channel(status: 0xC3, data1: 3, data2: nil)])
        #expect(try events(4, nil) == [.channel(status: 0xC3, data1: 4, data2: nil)])
        #expect(try events(5, Self.bank(5, 10)) == [.channel(status: 0xB3, data1: 0, data2: 5),
                                                    .channel(status: 0xB3, data1: 32, data2: 10),
                                                    .channel(status: 0xC3, data1: 5, data2: nil)])
        #expect(downward.losses.total == 0)
    }

    @Test func rpnAndNRPNAssembleWithDataEntryMSBAndLSB() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        let rpn = try Self.up([Self.cc(0, 101, 0), Self.cc(0, 100, 6), Self.cc(0, 6, 0x50), Self.cc(0, 38, 0x21),
                               Self.cc(0, 38, 0x22), Self.cc(0, 6, 0x51)], with: &upward)
        #expect(rpn[0].messages.isEmpty && rpn[1].messages.isEmpty)
        let zero = try Self.seven(0)
        let six = try Self.seven(6)
        #expect(rpn[2].messages == [try Self.mt4(0, 0, .registeredController(bank: zero, index: six,
                                                                              value: Self.data(0x50 << 7)))])
        #expect(rpn[3].messages == [try Self.mt4(0, 0, .registeredController(bank: zero, index: six,
                                                                              value: Self.data(0x50 << 7 | 0x21)))])
        #expect(rpn[4].messages == [try Self.mt4(0, 0, .registeredController(bank: zero, index: six,
                                                                              value: Self.data(0x50 << 7 | 0x22)))])
        // A new Data Entry MSB resets the LSB to 0.
        #expect(rpn[5].messages == [try Self.mt4(0, 0, .registeredController(bank: zero, index: six,
                                                                              value: Self.data(0x51 << 7)))])
        let nrpn = try Self.up([Self.cc(0, 99, 5), Self.cc(0, 98, 7), Self.cc(0, 6, 0x7F), Self.cc(0, 38, 0x7F)],
                               with: &upward)
        #expect(nrpn[2].messages == [try Self.mt4(0, 0, .assignableController(bank: Self.seven(5), index: Self.seven(7),
                                                                               value: Self.data(0x3F80)))])
        #expect(nrpn[3].messages == [try Self.mt4(0, 0, .assignableController(bank: Self.seven(5), index: Self.seven(7),
                                                                               value: 0xFFFF_FFFF))])
        #expect(upward.losses.total == 0)
    }

    @Test func dataEntryWithoutACompleteSelectionIsADeclaredLoss() throws {
        let sequences: [([UMPMIDI1ChannelVoice], UMPTranslationLossReason)] = try [
            ([Self.cc(0, 6, 1)], .dataEntryWithoutParameter),
            ([Self.cc(0, 38, 1)], .dataEntryWithoutParameter),
            ([Self.cc(0, 101, 0), Self.cc(0, 6, 1)], .dataEntryWithoutParameter),
            ([Self.cc(0, 100, 0), Self.cc(0, 6, 1)], .dataEntryWithoutParameter),
            ([Self.cc(0, 99, 0), Self.cc(0, 6, 1)], .dataEntryWithoutParameter),
            // Switching family clears the other selection byte.
            ([Self.cc(0, 101, 0), Self.cc(0, 100, 0), Self.cc(0, 99, 3), Self.cc(0, 6, 1)],
             .dataEntryWithoutParameter),
            ([Self.cc(0, 101, 0), Self.cc(0, 100, 0), Self.cc(0, 38, 1)], .dataEntryLSBWithoutMSB),
            // A new selection byte clears the Data Entry MSB.
            ([Self.cc(0, 101, 0), Self.cc(0, 100, 0), Self.cc(0, 6, 1), Self.cc(0, 100, 1), Self.cc(0, 38, 1)],
             .dataEntryLSBWithoutMSB)
        ]
        for (voices, reason) in sequences {
            var upward = UMPMIDI1ToMIDI2Translator()
            let outputs = try Self.up(voices, with: &upward)
            let last = try #require(outputs.last)
            #expect(last.messages.isEmpty, "\(voices.map(\.event))")
            #expect(last.losses.map(\.reason) == [reason], "\(voices.map(\.event))")
            #expect(upward.losses.total == 1)
        }
    }

    @Test func nullRPNDeselectsAndIsNeverSentDown() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        let outputs = try Self.up([Self.cc(0, 101, 0), Self.cc(0, 100, 0), Self.cc(0, 6, 2), Self.cc(0, 101, 127),
                                   Self.cc(0, 100, 127), Self.cc(0, 6, 3), Self.cc(0, 38, 3)], with: &upward)
        #expect(outputs[2].messages.count == 1)
        #expect(outputs[3].messages.isEmpty && outputs[4].messages.isEmpty)
        #expect(outputs[3].losses.isEmpty && outputs[4].losses.isEmpty)
        #expect(outputs[5].messages.isEmpty && outputs[6].messages.isEmpty)
        #expect(upward.losses.count(.dataEntryWithoutParameter) == 2)
        // NRPN 127/127 is an ordinary Assignable Controller address.
        let nrpn = try Self.up([Self.cc(0, 99, 127), Self.cc(0, 98, 127), Self.cc(0, 6, 1)], with: &upward)
        #expect(nrpn[2].messages == [try Self.mt4(0, 0, .assignableController(
            bank: Self.seven(127), index: Self.seven(127), value: Self.data(1 << 7)))])

        var downward = UMPMIDI2ToMIDI1Translator()
        let null = try downward.translate(Self.mt4(0, 0, .registeredController(
            bank: Self.seven(127), index: Self.seven(127), value: 0)))
        #expect(null.messages.isEmpty)
        #expect(null.losses.map(\.reason) == [.nullParameterAddress])
        #expect(downward.state(group: try UMPGroup(0), channel: try UMPChannel(0)) == UMPDownChannelState())
        let assignable = try downward.translate(Self.mt4(0, 0, .assignableController(
            bank: Self.seven(127), index: Self.seven(127), value: 0)))
        #expect(assignable.messages.map(\.event) == [.channel(status: 0xB0, data1: 99, data2: 127),
                                                     .channel(status: 0xB0, data1: 98, data2: 127),
                                                     .channel(status: 0xB0, data1: 6, data2: 0)])
    }

    @Test func downSendsOnlyTheParameterBytesThatChanged() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        func events(_ kind: UMPParameterKind, _ bank: UInt8, _ index: UInt8, _ fourteenBit: UInt32) throws
            -> [MIDI1Event] {
            let value = try Self.data(fourteenBit)
            let message: UMPMIDI2Message = kind == .registered
                ? .registeredController(bank: try Self.seven(bank), index: try Self.seven(index), value: value)
                : .assignableController(bank: try Self.seven(bank), index: try Self.seven(index), value: value)
            return try downward.translate(Self.mt4(0, 5, message)).messages.map(\.event)
        }
        func cc(_ controller: UInt8, _ value: UInt8) -> MIDI1Event {
            .channel(status: 0xB5, data1: controller, data2: value)
        }
        #expect(try events(.registered, 0, 0, 0x50 << 7 | 0x21) == [cc(101, 0), cc(100, 0), cc(6, 0x50), cc(38, 0x21)])
        #expect(try events(.registered, 0, 0, 0x50 << 7 | 0x22) == [cc(38, 0x22)])
        #expect(try events(.registered, 0, 0, 0x50 << 7) == [cc(38, 0)])
        #expect(try events(.registered, 0, 0, 0x51 << 7) == [cc(6, 0x51)])
        #expect(try events(.registered, 0, 1, 0x51 << 7) == [cc(101, 0), cc(100, 1), cc(6, 0x51)])
        #expect(try events(.assignable, 0, 1, 0x51 << 7) == [cc(99, 0), cc(98, 1), cc(6, 0x51)])
        // A value that does not survive 32 → 14 bits still sends its top 14 bits, with a declared loss.
        let lossy = try downward.translate(Self.mt4(0, 5, .assignableController(
            bank: Self.seven(0), index: Self.seven(1), value: Self.data(0x51 << 7) + 1)))
        #expect(lossy.messages.map(\.event) == [cc(38, 0)])
        #expect(lossy.losses.map(\.reason) == [.valueDownscaled])
    }

    @Test func canonicalMIDI1SequencesRoundTripExactly() throws {
        let sequences: [[UMPMIDI1ChannelVoice]] = try [
            [Self.cc(0, 0, 5), Self.cc(0, 32, 9), Self.program(0, 42), Self.program(0, 43), Self.program(0, 44)],
            [Self.cc(0, 0, 5), Self.cc(0, 32, 9), Self.program(0, 42), Self.cc(0, 0, 6), Self.cc(0, 32, 9),
             Self.program(0, 1)],
            [Self.cc(3, 101, 0), Self.cc(3, 100, 0), Self.cc(3, 6, 2), Self.cc(3, 38, 64), Self.cc(3, 38, 65),
             Self.cc(3, 6, 3), Self.cc(3, 6, 4), Self.cc(3, 38, 0)],
            [Self.cc(9, 99, 5), Self.cc(9, 98, 7), Self.cc(9, 6, 127), Self.cc(9, 38, 127), Self.cc(9, 101, 0),
             Self.cc(9, 100, 1), Self.cc(9, 6, 64)],
            // Interleaved channels and groups keep separate state.
            [Self.cc(1, 101, 0), Self.cc(1, 100, 6), Self.cc(1, 6, 12), Self.cc(0, 101, 0, group: 4),
             Self.cc(0, 100, 0, group: 4), Self.cc(0, 6, 2, group: 4), Self.cc(1, 38, 1), Self.cc(2, 7, 100),
             Self.program(1, 9), Self.cc(0, 38, 3, group: 4)]
        ]
        for voices in sequences {
            let result = try Self.roundTrip(voices)
            #expect(result.words == voices.map(\.packet.words[0]), "\(voices.map(\.event))")
            #expect(result.losses == 0)
        }
    }

    @Test func nonCanonicalSequencesRoundTripToTheSameReceiverState() throws {
        // Repeated selection or bank bytes collapse; a changed selection resends both bytes.
        let voices = try [Self.cc(0, 101, 0), Self.cc(0, 100, 0), Self.cc(0, 6, 2), Self.cc(0, 100, 1),
                          Self.cc(0, 6, 2), Self.cc(0, 32, 9), Self.cc(0, 0, 5), Self.cc(0, 0, 5), Self.program(0, 1)]
        let expected = try [Self.cc(0, 101, 0), Self.cc(0, 100, 0), Self.cc(0, 6, 2), Self.cc(0, 101, 0),
                            Self.cc(0, 100, 1), Self.cc(0, 6, 2), Self.cc(0, 0, 5), Self.cc(0, 32, 9),
                            Self.program(0, 1)]
        let result = try Self.roundTrip(voices)
        #expect(result.words == expected.map(\.packet.words[0]))
        #expect(result.losses == 0)
    }

    @Test func stateIsIsolatedPerGroupAndChannel() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        _ = try Self.up([Self.cc(3, 0, 5, group: 2), Self.cc(3, 32, 9, group: 2), Self.cc(3, 101, 0, group: 2),
                         Self.cc(3, 100, 0, group: 2)], with: &upward)
        let target = (group: try UMPGroup(2), channel: try UMPChannel(3))
        for group in UInt8(0)...15 {
            for channel in UInt8(0)...15 {
                let state = upward.state(group: try UMPGroup(group), channel: try UMPChannel(channel))
                let isTarget = group == 2 && channel == 3
                #expect((state == UMPUpChannelState()) != isTarget, "\(group)/\(channel)")
            }
        }
        #expect(upward.state(group: target.group, channel: target.channel).bank == (try Self.bank(5, 9)))
        let neighbours = try Self.up([Self.program(4, 1, group: 2), Self.program(3, 1, group: 3),
                                      Self.cc(4, 6, 1, group: 2), Self.cc(3, 6, 1, group: 3)], with: &upward)
        #expect(neighbours[0].messages.map(\.message) == [.programChange(program: try Self.seven(1), bank: nil)])
        #expect(neighbours[1].messages.map(\.message) == [.programChange(program: try Self.seven(1), bank: nil)])
        #expect(neighbours[2].losses.map(\.reason) == [.dataEntryWithoutParameter])
        #expect(neighbours[3].losses.map(\.reason) == [.dataEntryWithoutParameter])
        #expect(neighbours[3].losses.map(\.group) == [try UMPGroup(3)])

        var downward = UMPMIDI2ToMIDI1Translator()
        let message = UMPMIDI2Message.registeredController(bank: try Self.seven(0), index: try Self.seven(0), value: 0)
        // Each group/channel gets its own selection; the repeat on 0/0 sends only the Data Entry LSB.
        for (group, channel, count) in [(UInt8(0), UInt8(0), 3), (0, 1, 3), (1, 0, 3), (0, 0, 1)] {
            let output = try downward.translate(Self.mt4(group, channel, message))
            #expect(output.messages.count == count, "\(group)/\(channel)")
        }
    }

    @Test func stateTableIsBoundedToSixteenGroupsBySixteenChannels() throws {
        #expect(UMPTranslationTable<Int>.capacity == 256)
        var table = UMPTranslationTable(repeating: -1)
        for group in UInt8(0)...15 {
            for channel in UInt8(0)...15 {
                table[try UMPGroup(group), try UMPChannel(channel)] = Int(group) * 100 + Int(channel)
            }
        }
        for group in UInt8(0)...15 {
            for channel in UInt8(0)...15 {
                #expect(table[try UMPGroup(group), try UMPChannel(channel)] == Int(group) * 100 + Int(channel))
            }
        }
    }
}
