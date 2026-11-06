import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI 1↔2 translation data entry")
struct UMPTranslationDataEntryTests {
    static func cc(_ channel: UInt8, _ controller: UInt8, _ value: UInt8, group: UInt8 = 0) throws
        -> UMPMIDI1ChannelVoice {
        try UMPMIDI1ChannelVoice(group: UMPGroup(group), event: .channel(status: 0xB0 | channel, data1: controller,
                                                                           data2: value))
    }

    static func mt4(_ group: UInt8, _ channel: UInt8, _ message: UMPMIDI2Message) throws -> UMPMIDI2ChannelVoice {
        UMPMIDI2ChannelVoice(group: try UMPGroup(group), channel: try UMPChannel(channel), message: message)
    }

    static func seven(_ value: UInt8) throws -> UMPSevenBit { try UMPSevenBit(value) }

    static func bank(_ msb: UInt8, _ lsb: UInt8) throws -> UMPBankSelect {
        UMPBankSelect(msb: try seven(msb), lsb: try seven(lsb))
    }

    /// RPN `bank`/`index` (a MIDI 2.0 Registered Controller) carrying the upscale of a 14-bit Data Entry value.
    static func rpn(_ bank: UInt8, _ index: UInt8, _ fourteenBit: UInt32) throws -> UMPMIDI2Message {
        .registeredController(bank: try seven(bank), index: try seven(index),
                              value: try UMPScaling.scaleUp(fourteenBit, fromBits: 14, toBits: 32))
    }

    static func nrpn(_ bank: UInt8, _ index: UInt8, _ fourteenBit: UInt32) throws -> UMPMIDI2Message {
        .assignableController(bank: try seven(bank), index: try seven(index),
                              value: try UMPScaling.scaleUp(fourteenBit, fromBits: 14, toBits: 32))
    }

    static func midi1(_ channel: UInt8, _ pairs: [(UInt8, UInt8)]) -> [MIDI1Event] {
        pairs.map { .channel(status: 0xB0 | channel, data1: $0.0, data2: $0.1) }
    }

    static func loss(_ reason: UMPTranslationLossReason, _ group: UInt8 = 0, _ channel: UInt8 = 0) throws
        -> UMPTranslationLoss {
        UMPTranslationLoss(reason: reason, group: try UMPGroup(group), channel: try UMPChannel(channel))
    }

    @Test func dataEntryMSBIsHeldUntilItsLSBOrTheNextMessageOnItsGroupAndChannel() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        func messages(_ voice: UMPMIDI1ChannelVoice) throws -> [UMPMIDI2ChannelVoice] {
            try upward.translate(voice).messages
        }
        _ = try messages(Self.cc(0, 101, 0))
        _ = try messages(Self.cc(0, 100, 1))
        #expect(try messages(Self.cc(0, 6, 10)).isEmpty)
        // A second CC 6 sends the held one with LSB 0 first.
        #expect(try messages(Self.cc(0, 6, 11)) == [try Self.mt4(0, 0, Self.rpn(0, 1, 10 << 7))])
        // Any other message on the channel sends it first, in order.
        let note = try UMPMIDI1ChannelVoice(group: UMPGroup(0), event: .channel(status: 0x90, data1: 60, data2: 100))
        #expect(try messages(note) == [try Self.mt4(0, 0, Self.rpn(0, 1, 11 << 7)),
                                       try Self.mt4(0, 0, .noteOn(note: Self.seven(60), velocity: 0xC924,
                                                                  attributeType: 0, attribute: 0))])
        // Even an absorbed Bank Select sends it.
        _ = try messages(Self.cc(0, 6, 12))
        #expect(try messages(Self.cc(0, 0, 3)) == [try Self.mt4(0, 0, Self.rpn(0, 1, 12 << 7))])
        // CC 38 completes it into one write; a further CC 38 rewrites the LSB under the same MSB.
        _ = try messages(Self.cc(0, 6, 13))
        #expect(try messages(Self.cc(0, 38, 5)) == [try Self.mt4(0, 0, Self.rpn(0, 1, 13 << 7 | 5))])
        #expect(try messages(Self.cc(0, 38, 6)) == [try Self.mt4(0, 0, Self.rpn(0, 1, 13 << 7 | 6))])
        #expect(upward.flushAll().isEmpty)
        #expect(upward.losses.total == 0)
    }

    @Test func aHeldDataEntryIsSentBeforeTheNextMessageOnAnyGroupOrChannel() throws {
        let note = try UMPMIDI2Message.noteOn(note: Self.seven(60), velocity: 0xC924, attributeType: 0, attribute: 0)
        // MPE Configuration Message on channel 1, then a Note On on channel 2, in the same group or another one.
        for group: UInt8 in [0, 1] {
            var upward = UMPMIDI1ToMIDI2Translator()
            for (controller, value) in [(UInt8(101), UInt8(0)), (100, 6), (6, 15)] {
                #expect(try upward.translate(Self.cc(0, controller, value)).messages.isEmpty)
            }
            let noteOn = try UMPMIDI1ChannelVoice(group: UMPGroup(group), event: .channel(status: 0x91, data1: 60,
                                                                                        data2: 100))
            #expect(try upward.translate(noteOn).messages == [try Self.mt4(0, 0, Self.rpn(0, 6, 15 << 7)),
                                                              try Self.mt4(group, 1, note)], "group \(group)")
            #expect(upward.heldDataEntry == nil)
        }
        // A CC 38 on another channel sends the held CC 6 first, then is handled on its own channel.
        var upward = UMPMIDI1ToMIDI2Translator()
        for (channel, controller, value) in [(UInt8(1), UInt8(99), UInt8(2)), (1, 98, 3), (1, 6, 4),
                                             (0, 101, 0), (0, 100, 1), (0, 6, 9)] {
            _ = try upward.translate(Self.cc(channel, controller, value))
        }
        #expect(upward.heldDataEntry == (try Self.mt4(0, 0, Self.rpn(0, 1, 9 << 7))))
        #expect(try upward.translate(Self.cc(1, 38, 5)).messages == [try Self.mt4(0, 0, Self.rpn(0, 1, 9 << 7)),
                                                                     try Self.mt4(0, 1, Self.nrpn(2, 3, 4 << 7 | 5))])
        // A Program Change, or an NRPN -> RPN switch, sends the held CC 6 before it.
        _ = try upward.translate(Self.cc(0, 6, 10))
        let program = try upward.translate(UMPMIDI1ChannelVoice(group: UMPGroup(0),
                                                                event: .channel(status: 0xC0, data1: 7, data2: nil)))
        #expect(program.messages == [try Self.mt4(0, 0, Self.rpn(0, 1, 10 << 7)),
                                     try Self.mt4(0, 0, .programChange(program: Self.seven(7), bank: nil))])
        _ = try upward.translate(Self.cc(1, 6, 11))
        #expect(try upward.translate(Self.cc(1, 101, 0)).messages == [try Self.mt4(0, 1, Self.nrpn(2, 3, 11 << 7))])
        #expect(upward.state(group: try UMPGroup(0), channel: try UMPChannel(1)).parameterKind == .registered)
        #expect(upward.heldDataEntry == nil)
        #expect(upward.losses.total == 0)
    }

    @Test func flushSendsTheOneHeldDataEntryExactlyOnce() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        var sent: [UMPMIDI2ChannelVoice] = []
        for (group, channel, value) in [(UInt8(3), UInt8(2), UInt8(30)), (0, 5, 5), (0, 0, 1)] {
            for (controller, byte) in [(UInt8(99), UInt8(4)), (98, 8), (6, value)] {
                sent += try upward.translate(Self.cc(channel, controller, byte, group: group)).messages
                // At most one CC 6 is ever held, across all groups and channels.
                #expect(upward.heldDataEntry == nil || controller == 6)
            }
        }
        #expect(sent == [try Self.mt4(3, 2, Self.nrpn(4, 8, 30 << 7)), try Self.mt4(0, 5, Self.nrpn(4, 8, 5 << 7))])
        #expect(try upward.flush(group: UMPGroup(0), channel: UMPChannel(5)).isEmpty)
        #expect(try upward.flush(group: UMPGroup(1), channel: UMPChannel(0)).isEmpty)
        #expect(try upward.flush(group: UMPGroup(0), channel: UMPChannel(0))
            == [try Self.mt4(0, 0, Self.nrpn(4, 8, 1 << 7))])
        #expect(upward.flushAll().isEmpty)
        _ = try upward.translate(Self.cc(0, 6, 2))
        #expect(upward.flushAll() == [try Self.mt4(0, 0, Self.nrpn(4, 8, 2 << 7))])
        #expect(upward.flushAll().isEmpty)
        // Flushing keeps the Data Entry MSB, so a late CC 38 still completes the value.
        #expect(try upward.translate(Self.cc(2, 38, 7, group: 3)).messages
            == [try Self.mt4(3, 2, Self.nrpn(4, 8, 30 << 7 | 7))])
        #expect(try upward.translate(Self.cc(0, 38, 7)).messages == [try Self.mt4(0, 0, Self.nrpn(4, 8, 2 << 7 | 7))])
        #expect(upward.losses.total == 0)
    }

    @Test func exactlyRepresentableMIDI2WritesRoundTripTwoToOneToTwoAsOneMessage() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        var upward = UMPMIDI1ToMIDI2Translator()
        var checked = 0
        var failures: [String] = []
        func check(_ voice: UMPMIDI2ChannelVoice) throws {
            let midi1 = try downward.translate(voice)
            var back: [UMPMIDI2ChannelVoice] = []
            for message in midi1.messages { back += try upward.translate(message).messages }
            if back != [voice] || !midi1.losses.isEmpty { failures.append("\(voice.group.value) \(voice.message)") }
            checked += 1
        }
        // Every 14-bit value on one RPN and one NRPN address.
        for value in UInt32(0)...0x3FFF {
            try check(Self.mt4(0, 0, Self.rpn(0, 7, value)))
            try check(Self.mt4(0, 0, Self.nrpn(0, 7, value)))
        }
        // Every address of both kinds except the null RPN, across every group and channel.
        for bank in UInt8(0)...127 {
            for index in UInt8(0)...127 {
                let value = (UInt32(bank) << 7 | UInt32(index)) ^ 0x2AAA
                try check(Self.mt4(bank & 15, index & 15, Self.nrpn(bank, index, value)))
                if bank == 127, index == 127 { continue }
                try check(Self.mt4(index & 15, bank & 15, Self.rpn(bank, index, value)))
            }
        }
        // Program Change with every bank, then every program on one bank.
        for msb in UInt8(0)...127 {
            for lsb in UInt8(0)...127 {
                try check(Self.mt4(msb & 15, lsb & 15, .programChange(program: Self.seven((msb ^ lsb) & 0x7F),
                                                                      bank: Self.bank(msb, lsb))))
            }
        }
        for program in UInt8(0)...127 {
            try check(Self.mt4(5, 5, .programChange(program: Self.seven(program), bank: Self.bank(1, 2))))
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(checked == 2 * 16_384 + (2 * 16_384 - 1) + 16_384 + 128)
        #expect(downward.losses.total == 0)
        #expect(upward.losses.total == 0)
        #expect(upward.flushAll().isEmpty)
    }

    @Test func dataIncrementDownForgetsTheDataEntryMSB() throws {
        for increment: UInt8 in [96, 97] {
            var downward = UMPMIDI2ToMIDI1Translator()
            func events(_ message: UMPMIDI2Message) throws -> [MIDI1Event] {
                try downward.translate(Self.mt4(0, 0, message)).messages.map(\.event)
            }
            #expect(try events(Self.rpn(0, 1, 255)) == Self.midi1(0, [(101, 0), (100, 1), (6, 1), (38, 127)]))
            #expect(try events(.controlChange(index: Self.seven(increment), value: 0))
                == Self.midi1(0, [(increment, 0)]))
            #expect(downward.state(group: try UMPGroup(0), channel: try UMPChannel(0)).dataEntryMSB == nil)
            // The receiver's value moved, so CC 6 is sent again even though the MSB is unchanged.
            #expect(try events(Self.rpn(0, 1, 129)) == Self.midi1(0, [(6, 1), (38, 1)]), "CC \(increment)")
            #expect(downward.losses.total == 0)
        }
    }

    @Test func dataIncrementUnmappedIsADeclaredLossUpward() throws {
        for increment: UInt8 in [96, 97] {
            var upward = UMPMIDI1ToMIDI2Translator()
            // Without any selected parameter.
            #expect(try upward.translate(Self.cc(0, increment, 1)) == UMPTranslationOutput(
                messages: [], losses: [try Self.loss(.dataIncrementUnmapped)]))
            // With a selected parameter and a complete value: not forwarded, and the MSB is forgotten.
            for (controller, value) in [(UInt8(101), UInt8(0)), (100, 1), (6, 1), (38, 127)] {
                _ = try upward.translate(Self.cc(0, controller, value))
            }
            #expect(try upward.translate(Self.cc(0, increment, 0)) == UMPTranslationOutput(
                messages: [], losses: [try Self.loss(.dataIncrementUnmapped)]))
            #expect(try upward.translate(Self.cc(0, 38, 1)).losses == [try Self.loss(.dataEntryLSBWithoutMSB)])
            // A held CC 6 is sent first; the selection survives.
            #expect(try upward.translate(Self.cc(0, 6, 3)).messages.isEmpty)
            let held = try upward.translate(Self.cc(0, increment, 0))
            #expect(held.messages == [try Self.mt4(0, 0, Self.rpn(0, 1, 3 << 7))])
            #expect(held.losses == [try Self.loss(.dataIncrementUnmapped)])
            #expect(upward.state(group: try UMPGroup(0), channel: try UMPChannel(0)).parameter != nil)
            #expect(upward.losses.count(.dataIncrementUnmapped) == 3)
            #expect(upward.losses.total == 4, "CC \(increment)")
        }
    }

    @Test func resetAllControllersUpForgetsTheSelectionAndKeepsTheBank() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        for (controller, value) in [(UInt8(0), UInt8(5)), (32, 9), (101, 0), (100, 1), (6, 5)] {
            _ = try upward.translate(Self.cc(4, controller, value, group: 2))
        }
        let reset = try upward.translate(Self.cc(4, 121, 0, group: 2))
        #expect(reset.messages == [try Self.mt4(2, 4, Self.rpn(0, 1, 5 << 7)),
                                   try Self.mt4(2, 4, .controlChange(index: Self.seven(121), value: 0))])
        var expected = UMPUpChannelState()
        expected.bankMSB = try Self.seven(5)
        expected.bankLSB = try Self.seven(9)
        #expect(upward.state(group: try UMPGroup(2), channel: try UMPChannel(4)) == expected)
        #expect(try upward.translate(Self.cc(4, 6, 1, group: 2)).losses
            == [try Self.loss(.dataEntryWithoutParameter, 2, 4)])
        let program = try upward.translate(UMPMIDI1ChannelVoice(group: UMPGroup(2),
                                                                event: .channel(status: 0xC4, data1: 3, data2: nil)))
        #expect(program.messages == [try Self.mt4(2, 4, .programChange(program: Self.seven(3), bank: Self.bank(5, 9)))])
    }

    @Test func resetAllControllersDownResendsTheSelectionAndKeepsTheBank() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        func events(_ message: UMPMIDI2Message) throws -> [MIDI1Event] {
            try downward.translate(Self.mt4(1, 6, message)).messages.map(\.event)
        }
        let program = UMPMIDI2Message.programChange(program: try Self.seven(3), bank: try Self.bank(5, 9))
        #expect(try events(program).count == 3)
        #expect(try events(Self.rpn(0, 1, 300)) == Self.midi1(6, [(101, 0), (100, 1), (6, 2), (38, 44)]))
        #expect(try events(.controlChange(index: Self.seven(121), value: 0)) == Self.midi1(6, [(121, 0)]))
        var expected = UMPDownChannelState()
        expected.bank = try Self.bank(5, 9)
        #expect(downward.state(group: try UMPGroup(1), channel: try UMPChannel(6)) == expected)
        #expect(try events(Self.rpn(0, 1, 300)) == Self.midi1(6, [(101, 0), (100, 1), (6, 2), (38, 44)]))
        #expect(try events(program) == [.channel(status: 0xC6, data1: 3, data2: nil)])
    }

    @Test func resetForgetsOneGroupAndChannelOnly() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        let program = UMPMIDI2Message.programChange(program: try Self.seven(3), bank: try Self.bank(5, 9))
        for channel: UInt8 in [0, 1] {
            _ = try downward.translate(Self.mt4(0, channel, program))
            _ = try downward.translate(Self.mt4(0, channel, Self.rpn(0, 1, 300)))
        }
        let kept = downward.state(group: try UMPGroup(0), channel: try UMPChannel(1))
        downward.reset(group: try UMPGroup(0), channel: try UMPChannel(0))
        #expect(downward.state(group: try UMPGroup(0), channel: try UMPChannel(0)) == UMPDownChannelState())
        #expect(downward.state(group: try UMPGroup(0), channel: try UMPChannel(1)) == kept)
        #expect(try downward.translate(Self.mt4(0, 0, Self.rpn(0, 1, 300))).messages.count == 4)
        #expect(try downward.translate(Self.mt4(0, 0, program)).messages.count == 3)
        #expect(try downward.translate(Self.mt4(0, 1, Self.rpn(0, 1, 300))).messages.count == 1)

        var upward = UMPMIDI1ToMIDI2Translator()
        for channel: UInt8 in [4, 3] {
            for (controller, value) in [(UInt8(0), UInt8(5)), (32, 9), (99, 0), (98, 1), (6, 5)] {
                _ = try upward.translate(Self.cc(channel, controller, value, group: 2))
            }
        }
        let other = upward.state(group: try UMPGroup(2), channel: try UMPChannel(4))
        // The held value was set by the sender, so reset sends it rather than discarding it.
        #expect(upward.reset(group: try UMPGroup(2), channel: try UMPChannel(3))
            == [try Self.mt4(2, 3, Self.nrpn(0, 1, 5 << 7))])
        #expect(upward.state(group: try UMPGroup(2), channel: try UMPChannel(3)) == UMPUpChannelState())
        #expect(upward.state(group: try UMPGroup(2), channel: try UMPChannel(4)) == other)
        #expect(try upward.translate(Self.cc(3, 38, 1, group: 2)).losses
            == [try Self.loss(.dataEntryWithoutParameter, 2, 3)])
        #expect(upward.flushAll().isEmpty)
        #expect(try upward.translate(Self.cc(4, 38, 1, group: 2)).messages
            == [try Self.mt4(2, 4, Self.nrpn(0, 1, 5 << 7 | 1))])
    }
}
