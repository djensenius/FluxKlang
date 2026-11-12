import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// MT 0x4 captures that write nothing, that the clip refuses, that cannot be decoded, and the default length.
extension CaptureSMFExportTests {
    /// A capture the translator turns into no MIDI 1 message, and the losses a genuine MIDI 2.0 endpoint counts for it.
    private struct SilentVoice {
        let name: String
        let words: [UInt32]
        let genuine: [SMFExportLoss: Int]
    }

    private static var silentVoices: [SilentVoice] {
        var voices = [0, 6, 32, 38, 98, 99, 100, 101].map {
            SilentVoice(name: "CC \($0)", words: Fixture.controlChange2(1, $0, Fixture.exactLow),
                        genuine: [.umpOnlyDropped: 1])
        }
        voices += [
            SilentVoice(name: "null RPN", words: Fixture.parameter2(1, 127, 127, Fixture.exactLow),
                        genuine: [.umpOnlyDropped: 1]),
            SilentVoice(name: "registered per-note", words: Fixture.voice2(0x0, 1, 60, 1, data: Fixture.exactLow),
                        genuine: [.perNoteDropped: 1]),
            SilentVoice(name: "assignable per-note", words: Fixture.voice2(0x1, 1, 60, 1, data: Fixture.exactLow),
                        genuine: [.perNoteDropped: 1]),
            SilentVoice(name: "per-note pitch bend", words: Fixture.voice2(0x6, 1, 60, data: Fixture.exactMid),
                        genuine: [.perNoteDropped: 1]),
            SilentVoice(name: "per-note management", words: Fixture.voice2(0xF, 1, 60, 1, data: 0),
                        genuine: [.perNoteDropped: 1]),
            SilentVoice(name: "relative registered", words: Fixture.voice2(0x4, 1, 1, 2, data: 5),
                        genuine: [.umpOnlyDropped: 1]),
            SilentVoice(name: "relative assignable", words: Fixture.voice2(0x5, 1, 1, 2, data: 5),
                        genuine: [.umpOnlyDropped: 1])
        ]
        return voices
    }

    @Test func aVoiceThatTranslatesToNothingIsCountedOnceWhoeverClassifiedIt() throws {
        for voice in Self.silentVoices {
            let others: [(MIDIEndpointProtocol, [SMFExportLoss: Int])] = [
                (.midi2, voice.genuine), (.unknown, [.fidelityUnverified: 1, .umpOnlyDropped: 1]),
                (.midi1, [.umpOnlyDropped: 1])]
            for (endpoint, losses) in others {
                var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
                try feed.add(Fixture.streamB, Fixture.noteOn(1, 60, 64), tick: 0)
                try feed.addMIDI2(Fixture.streamA, voice.words, tick: 10, endpoint: endpoint)
                try feed.add(Fixture.streamB, Fixture.noteOff(1, 60, 64), tick: 20)
                let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
                #expect(export.clip.items == [Fixture.note(1, 60, velocity: 64, from: 0, to: 20)],
                        "\(voice.name) \(endpoint)")
                #expect(export.smf().losses.losses == losses, "\(voice.name) \(endpoint)")
                #expect(export.droppedUMPOnly == losses[.umpOnlyDropped] ?? 0, "\(voice.name) \(endpoint)")
                #expect(!export.smf().losses.lossless, "\(voice.name) \(endpoint)")
                var alone = try Fixture.Feed([Fixture.streamA])
                try alone.addMIDI2(Fixture.streamA, voice.words, tick: 10, endpoint: endpoint)
                #expect(Fixture.refusal(alone.log, [Fixture.streamA]) == .nothingExportable(dropped: 1),
                        "\(voice.name) \(endpoint)")
            }
        }
    }

    @Test func nothingExportableCountsEveryCaptureTheFileLacks() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.addMIDI2(Fixture.streamA, Fixture.controlChange2(1, 38, Fixture.exactLow), tick: 10)
        try feed.addMIDI2(Fixture.streamA, Fixture.voice2(0x6, 1, 60, data: Fixture.exactMid), tick: 20)
        try feed.add(Fixture.streamB, Fixture.data128, tick: 30)
        try feed.add(Fixture.streamB, Fixture.orphanSysEx, tick: 40)
        try feed.add(Fixture.streamB, Fixture.utility, tick: 50)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB]) == .nothingExportable(dropped: 5))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .nothingExportable(dropped: 2))
    }

    @Test func aHoldOrChannelModeControllerFromMIDI2IsRefusedByTheClipLikeAMIDI1One() throws {
        for controller: UInt8 in [64, 66, 69, 120, 121, 127] {
            var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
            try feed.add(Fixture.streamB, Fixture.noteOn(1, 60, 64), tick: 0)
            try feed.add(Fixture.streamB, Fixture.noteOff(1, 60, 64), tick: 10)
            try feed.addMIDI2(Fixture.streamA, Fixture.controlChange2(1, controller, Fixture.exactLow), tick: 20)
            #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB])
                        == .clip(.unsupportedMessage(item: 1)), "CC \(controller)")
        }
    }

    @Test func aReservedStatusInAMIDI2CaptureRefusesWithItsExactPayload() throws {
        let streams = [Fixture.streamA, Fixture.streamB, Fixture.streamC]
        var feed = try Fixture.Feed(streams)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.addMIDI2(Fixture.streamA, [0x4070_0000, 0], tick: 10)
        try feed.add(Fixture.streamB, [0x2000_0000], tick: 20)
        try feed.addMIDI2(Fixture.streamC, [0x4070_0000, 0], tick: 30)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB]) == .invalidChannelVoice(
            stream: Fixture.streamA, index: 1, .reservedStatus(mt: .midi2ChannelVoice, status: 7)))
        #expect(Fixture.refusal(feed.log, [Fixture.streamC]) == .invalidChannelVoice(
            stream: Fixture.streamC, index: 3, .reservedStatus(mt: .midi2ChannelVoice, status: 7)))
        var other = try Fixture.Feed(streams)
        try other.add(Fixture.streamB, [0x2000_0000], tick: 10)
        try other.addMIDI2(Fixture.streamA, [0x4070_0000, 0], tick: 20)
        #expect(Fixture.refusal(other.log, [Fixture.streamA, Fixture.streamB]) == .invalidChannelVoice(
            stream: Fixture.streamB, index: 0, .reservedStatus(mt: .midi1ChannelVoice, status: 0)))
    }

    @Test func aCaptureOfAnUnselectedStreamIsNeverDecoded() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.addMIDI2(Fixture.streamB, [0x4070_0000, 0], tick: 5)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items == [Fixture.note(1, 60, velocity: 64, from: 0, to: 10)])
        #expect(export.smf().losses.losses == [:])
    }

    @Test func aLogOfMIDI2CapturesOnlyExportsWithTheDefaultLength() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.addMIDI2(Fixture.streamA, Fixture.noteOn2(1, 60, 0xC924), tick: 100)
        try feed.addMIDI2(Fixture.streamA, Fixture.noteOff2(1, 60, 0), tick: 15_359)
        #expect(try Fixture.export(feed.log, [Fixture.streamA]).clip.lengthTicks == MusicalTime.ticksPerQuarter)
        try feed.addMIDI2(Fixture.streamA, Fixture.noteOn2(1, 61, 0xC924), tick: 15_360)
        try feed.addMIDI2(Fixture.streamA, Fixture.noteOff2(1, 61, 0), tick: 15_361)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.lengthTicks == 2 * MusicalTime.ticksPerQuarter)
        #expect(export.clip.items == [Fixture.note(1, 60, velocity: 100, release: 0, from: 100, to: 15_359),
                                      Fixture.note(1, 61, velocity: 100, release: 0, from: 15_360, to: 15_361)])
    }

    @Test func aMIDI2CaptureLaterThanEveryMIDI1CaptureExtendsTheDefaultLength() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 100)
        try feed.addMIDI2(Fixture.streamB, Fixture.voice2(0x6, 1, 60, data: Fixture.exactMid), tick: 20_000)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.clip.lengthTicks == 2 * MusicalTime.ticksPerQuarter)
        #expect(try Fixture.export(feed.log, [Fixture.streamA]).clip.lengthTicks == MusicalTime.ticksPerQuarter)
    }

    @Test func anOutOfRangeDefaultLengthFromAMIDI2CaptureWinsOverItsUndecodablePacket() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamB, Fixture.controlChange(1, 7, 100), tick: 0)
        try feed.addMIDI2(Fixture.streamA, [0x4070_0000, 0], tick: MIDIClip.maximumLengthTicks)
        let inferred = MIDIClip.maximumLengthTicks + MusicalTime.ticksPerQuarter
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB]) == .lengthOutOfRange(inferred))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB], length: 1) == .invalidChannelVoice(
            stream: Fixture.streamA, index: 1, .reservedStatus(mt: .midi2ChannelVoice, status: 7)))
    }
}
