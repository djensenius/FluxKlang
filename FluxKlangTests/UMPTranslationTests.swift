import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI 1↔2 translation")
struct UMPTranslationTests {
    static func mt2(_ group: UInt8, _ status: UInt8, _ data1: UInt8, _ data2: UInt8?) throws -> UMPMIDI1ChannelVoice {
        try UMPMIDI1ChannelVoice(group: UMPGroup(group), event: .channel(status: status, data1: data1, data2: data2))
    }

    static func mt4(_ group: UInt8, _ channel: UInt8, _ message: UMPMIDI2Message) throws -> UMPMIDI2ChannelVoice {
        UMPMIDI2ChannelVoice(group: try UMPGroup(group), channel: try UMPChannel(channel), message: message)
    }

    static func seven(_ value: UInt8) throws -> UMPSevenBit { try UMPSevenBit(value) }

    /// Translates `message` down with a fresh translator and returns its output.
    static func down(_ message: UMPMIDI2Message) throws -> UMPTranslationOutput<UMPMIDI1ChannelVoice> {
        var translator = UMPMIDI2ToMIDI1Translator()
        return try translator.translate(mt4(0, 0, message))
    }

    static func reasons(_ losses: [UMPTranslationLoss]) -> [UMPTranslationLossReason] { losses.map(\.reason) }

    /// Controllers the translators handle statefully (bank select, data entry, NRPN and RPN selection).
    static let statefulControllers: Set<UInt8> = [0, 6, 32, 38, 98, 99, 100, 101]

    @Test func midi1ToMIDI2ToMIDI1IsTheIdentityForEveryStatelessMessage() throws {
        // Every status 0x80...0xEF with every data byte pair. One translator pair for the whole sweep, so no state
        // may leak between messages. Group varies with the channel so every group is used too.
        var upward = UMPMIDI1ToMIDI2Translator()
        var downward = UMPMIDI2ToMIDI1Translator()
        var checked = 0
        var failures: [String] = []
        for status in UInt8(0x80)...0xEF {
            let single = (0xC0...0xDF).contains(status)
            for data1 in UInt8(0)...127 {
                if status & 0xF0 == 0xB0, Self.statefulControllers.contains(data1) { continue }
                for data2 in single ? [nil] : (UInt8(0)...127).map(Optional.some) {
                    let voice = try Self.mt2(status & 0x0F, status, data1, data2)
                    let mid = try upward.translate(voice)
                    guard mid.messages.count == 1, mid.losses.isEmpty else {
                        failures.append("up \(status) \(data1) \(String(describing: data2))")
                        continue
                    }
                    let back = try downward.translate(mid.messages[0])
                    // A MIDI 1.0 Note On with velocity 0 means Note Off (velocity 64): only its meaning returns.
                    let noteOnZero = status & 0xF0 == 0x90 && data2 == 0
                    let same = back.messages.count == 1 && back.losses.isEmpty
                        && back.messages[0].semantic == voice.semantic
                        && (noteOnZero || back.messages[0].packet == voice.packet)
                    if !same { failures.append("down \(status) \(data1) \(String(describing: data2))") }
                    checked += 1
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        // 16 channels × (4 two-byte families × 128² + 120 controllers × 128 + 2 one-byte families × 128).
        #expect(checked == 1_298_432)
        #expect(upward.losses.total == 0)
        #expect(downward.losses.total == 0)
    }

    @Test func midi1NoteOnVelocityZeroRoundTripsAsNoteOffVelocity64() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        let mid = try upward.translate(Self.mt2(2, 0x93, 60, 0))
        #expect(mid.messages == [try Self.mt4(2, 3, .noteOff(note: Self.seven(60), velocity: 0x8000,
                                                               attributeType: 0, attribute: 0))])
        var downward = UMPMIDI2ToMIDI1Translator()
        let back = try downward.translate(mid.messages[0])
        #expect(back.messages.map(\.event) == [.channel(status: 0x83, data1: 60, data2: 64)])
    }

    @Test func upScalesOnlyThroughUMPScaling() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        func only(_ voice: UMPMIDI1ChannelVoice) throws -> UMPMIDI2Message? {
            let output = try upward.translate(voice)
            return output.messages.count == 1 && output.losses.isEmpty ? output.messages[0].message : nil
        }
        // Contract vector (media-contract §9.3) and the 7→32 centre.
        #expect(try only(Self.mt2(0, 0x90, 60, 100))
            == .noteOn(note: Self.seven(60), velocity: 0xC924, attributeType: 0, attribute: 0))
        #expect(try only(Self.mt2(0, 0xB0, 7, 64)) == .controlChange(index: Self.seven(7), value: 0x8000_0000))
        for value in UInt8(0)...127 {
            let to16 = UInt16(try UMPScaling.scaleUp(UInt32(value), fromBits: 7, toBits: 16))
            let to32 = try UMPScaling.scaleUp(UInt32(value), fromBits: 7, toBits: 32)
            #expect(try only(Self.mt2(0, 0x80, 1, value))
                == .noteOff(note: Self.seven(1), velocity: to16, attributeType: 0, attribute: 0))
            #expect(try only(Self.mt2(0, 0xA0, 1, value)) == .polyPressure(note: Self.seven(1), value: to32))
            #expect(try only(Self.mt2(0, 0xB0, 1, value)) == .controlChange(index: Self.seven(1), value: to32))
            #expect(try only(Self.mt2(0, 0xD0, value, nil)) == .channelPressure(value: to32))
        }
        for bend: UInt16 in [0, 1, 0x1FFF, 0x2000, 0x2001, 0x3FFE, 0x3FFF] {
            let to32 = try UMPScaling.scaleUp(UInt32(bend), fromBits: 14, toBits: 32)
            #expect(try only(Self.mt2(0, 0xE0, UInt8(bend & 0x7F), UInt8(bend >> 7))) == .pitchBend(value: to32))
        }
        #expect(try only(Self.mt2(0, 0xE0, 0, 0x40)) == .pitchBend(value: 0x8000_0000))
        #expect(try only(Self.mt2(0, 0xE0, 0x7F, 0x7F)) == .pitchBend(value: 0xFFFF_FFFF))
    }

    @Test func upKeepsGroupAndChannelInTheMT4Words() throws {
        var upward = UMPMIDI1ToMIDI2Translator()
        let output = try upward.translate(Self.mt2(3, 0x95, 0x3C, 100))
        #expect(output.messages.map(\.packet.words) == [[0x4395_3C00, 0xC924_0000]])
        let last = try upward.translate(Self.mt2(15, 0xCF, 5, nil))
        #expect(last.messages.map(\.packet.words) == [[0x4FCF_0000, 0x0500_0000]])
    }

    @Test func downKeepsGroupAndChannelInTheMT2Word() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        let output = try downward.translate(Self.mt4(15, 14, .noteOn(note: Self.seven(0x40), velocity: 0xFFFF,
                                                                   attributeType: 0, attribute: 0)))
        #expect(output.messages.map(\.packet.words) == [[0x2F9E_407F]])
        let bend = try downward.translate(Self.mt4(7, 1, .pitchBend(value: 0x8000_0000)))
        #expect(bend.messages.map(\.packet.words) == [[0x27E1_0040]])
    }

    @Test func midi2NoteOnWhoseVelocityScalesToZeroIsSentWithVelocityOne() throws {
        for velocity: UInt16 in [0x0000, 0x0001, 0x0100, 0x01FF] {
            let output = try Self.down(.noteOn(note: Self.seven(60), velocity: velocity, attributeType: 0,
                                               attribute: 0))
            #expect(output.messages.map(\.event) == [.channel(status: 0x90, data1: 60, data2: 1)], "\(velocity)")
            #expect(output.messages.map(\.semantic) == [.noteOn(channel: 1, note: 60, velocity: 1)])
            #expect(Self.reasons(output.losses).contains(.noteOnVelocityRemapped))
        }
        // 0x0000 is the upscale of 0, so only the remap is declared; 0x0100 also lost precision.
        #expect(Self.reasons(try Self.down(.noteOn(note: Self.seven(60), velocity: 0, attributeType: 0, attribute: 0))
            .losses) == [.noteOnVelocityRemapped])
        let lowest = try Self.down(.noteOn(note: Self.seven(60), velocity: 0x0100, attributeType: 0, attribute: 0))
        #expect(Self.reasons(lowest.losses) == [.velocityDownscaled, .noteOnVelocityRemapped])
        // 0x0200 scales to 1 already: no remap.
        let one = try Self.down(.noteOn(note: Self.seven(60), velocity: 0x0200, attributeType: 0, attribute: 0))
        #expect(one.messages.map(\.event) == [.channel(status: 0x90, data1: 60, data2: 1)])
        #expect(one.losses.isEmpty)
        // A Note Off with velocity 0 stays a Note Off with velocity 0.
        let off = try Self.down(.noteOff(note: Self.seven(60), velocity: 0, attributeType: 0, attribute: 0))
        #expect(off.messages.map(\.event) == [.channel(status: 0x80, data1: 60, data2: 0)])
        #expect(off.losses.isEmpty)
    }

    @Test func downDeclaresPrecisionLossesOnlyWhenTheValueDoesNotSurvive() throws {
        let note = try Self.seven(1)
        #expect(try Self.down(.noteOn(note: note, velocity: 0xC924, attributeType: 0, attribute: 0)).losses.isEmpty)
        let velocity = try Self.down(.noteOff(note: note, velocity: 0xC925, attributeType: 0, attribute: 0))
        #expect(velocity.messages.map(\.event) == [.channel(status: 0x80, data1: 1, data2: 100)])
        #expect(Self.reasons(velocity.losses) == [.velocityDownscaled])
        let cases: [(UMPMIDI2Message, MIDI1Event)] = [
            (.controlChange(index: note, value: 0x8000_0001), .channel(status: 0xB0, data1: 1, data2: 64)),
            (.polyPressure(note: note, value: 0xFFFF_FFFE), .channel(status: 0xA0, data1: 1, data2: 127)),
            (.channelPressure(value: 0x0000_0001), .channel(status: 0xD0, data1: 0, data2: nil)),
            (.pitchBend(value: 0x8000_0001), .channel(status: 0xE0, data1: 0, data2: 0x40))
        ]
        for (message, event) in cases {
            let output = try Self.down(message)
            #expect(output.messages.map(\.event) == [event], "\(message)")
            #expect(Self.reasons(output.losses) == [.valueDownscaled], "\(message)")
        }
        #expect(try Self.down(.controlChange(index: note, value: 0x8000_0000)).losses.isEmpty)
        #expect(try Self.down(.polyPressure(note: note, value: 0xFFFF_FFFF)).losses.isEmpty)
        #expect(try Self.down(.channelPressure(value: 0)).losses.isEmpty)
        #expect(try Self.down(.pitchBend(value: 0x8000_0000)).losses.isEmpty)
        #expect(try Self.down(.pitchBend(value: 0xFFFF_FFFF)).messages.map(\.event)
            == [.channel(status: 0xE0, data1: 0x7F, data2: 0x7F)])
    }

    @Test func midi2OnlyMessagesAreCountedLossesNeverSilentDrops() throws {
        let note = try Self.seven(9)
        let bank = try Self.seven(1)
        let cases: [(UMPMIDI2Message, UMPTranslationLossReason)] = [
            (.registeredPerNoteController(note: note, index: 3, value: 7), .perNoteController),
            (.assignablePerNoteController(note: note, index: 3, value: 7), .perNoteController),
            (.perNotePitchBend(note: note, value: 0x8000_0000), .perNotePitchBend),
            (.perNoteManagement(note: note, detach: true, reset: true), .perNoteManagement),
            (.relativeRegisteredController(bank: bank, index: bank, delta: -5), .relativeController),
            (.relativeAssignableController(bank: bank, index: bank, delta: 5), .relativeController)
        ]
        var downward = UMPMIDI2ToMIDI1Translator()
        for (message, reason) in cases {
            let output = try downward.translate(Self.mt4(4, 9, message))
            #expect(output.messages.isEmpty, "\(message)")
            #expect(output.losses == [UMPTranslationLoss(reason: reason, group: try UMPGroup(4),
                                                         channel: try UMPChannel(9))], "\(message)")
        }
        #expect(downward.losses.count(.perNoteController) == 2)
        #expect(downward.losses.count(.perNotePitchBend) == 1)
        #expect(downward.losses.count(.perNoteManagement) == 1)
        #expect(downward.losses.count(.relativeController) == 2)
        #expect(downward.losses.total == 6)
        // Translating them changes no state.
        #expect(downward.state(group: try UMPGroup(4), channel: try UMPChannel(9)) == UMPDownChannelState())
    }

    @Test func noteAttributesAreDroppedWithADeclaredLoss() throws {
        let note = try Self.seven(60)
        for (type, attribute, lost) in [(UInt8(0), UInt16(0), false), (3, 0x1234, true), (0, 1, true), (1, 0, true)] {
            let noteOn = try Self.down(.noteOn(note: note, velocity: 0xFFFF, attributeType: type, attribute: attribute))
            let noteOff = try Self.down(.noteOff(note: note, velocity: 0, attributeType: type, attribute: attribute))
            #expect(noteOn.messages.map(\.event) == [.channel(status: 0x90, data1: 60, data2: 127)])
            #expect(noteOff.messages.map(\.event) == [.channel(status: 0x80, data1: 60, data2: 0)])
            #expect(Self.reasons(noteOn.losses) == (lost ? [.attributeDropped] : []), "\(type) \(attribute)")
            #expect(Self.reasons(noteOff.losses) == (lost ? [.attributeDropped] : []), "\(type) \(attribute)")
        }
    }

    @Test func midi2ControlChangesOnStatefulIndicesAreDeclaredLosses() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        for index in Self.statefulControllers.sorted() {
            let output = try downward.translate(Self.mt4(0, 0, .controlChange(index: Self.seven(index), value: 0)))
            #expect(output.messages.isEmpty, "\(index)")
            #expect(Self.reasons(output.losses) == [.controllerReservedInMIDI2], "\(index)")
        }
        #expect(downward.losses.count(.controllerReservedInMIDI2) == Self.statefulControllers.count)
        #expect(downward.state(group: try UMPGroup(0), channel: try UMPChannel(0)) == UMPDownChannelState())
        for index: UInt8 in [1, 5, 7, 31, 33, 37, 39, 96, 97, 102, 127] {
            let output = try downward.translate(Self.mt4(0, 0, .controlChange(index: Self.seven(index), value: 0)))
            #expect(output.messages.map(\.event) == [.channel(status: 0xB0, data1: index, data2: 0)], "\(index)")
        }
    }

    @Test func lossCountsAccumulateAcrossCallsAndCopiesAreIndependent() throws {
        var downward = UMPMIDI2ToMIDI1Translator()
        _ = try downward.translate(Self.mt4(0, 0, .perNotePitchBend(note: Self.seven(1), value: 0)))
        let copy = downward
        _ = try downward.translate(Self.mt4(0, 0, .perNotePitchBend(note: Self.seven(1), value: 0)))
        _ = try downward.translate(Self.mt4(1, 2, .noteOn(note: Self.seven(1), velocity: 0, attributeType: 9,
                                                       attribute: 0)))
        #expect(copy.losses.total == 1)
        #expect(downward.losses.count(.perNotePitchBend) == 2)
        #expect(downward.losses.count(.attributeDropped) == 1)
        #expect(downward.losses.count(.noteOnVelocityRemapped) == 1)
        #expect(downward.losses.total == 4)
        for reason in UMPTranslationLossReason.allCases where ![.perNotePitchBend, .attributeDropped,
                                                               .noteOnVelocityRemapped].contains(reason) {
            #expect(downward.losses.count(reason) == 0, "\(reason)")
        }
    }
}
