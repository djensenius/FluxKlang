import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The #112 CL5 suites: MIDI 1 captures exported as a clip and a Standard MIDI File. The helpers live in the nested
/// `Fixture` so no name is shared with another test file of the module.
@Suite("Capture SMF export")
struct CaptureSMFExportTests {
    @Test func eightPairedNotesOnTwoChannelsRoundTripThroughTheSMFReader() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        for index in 0..<4 {
            let low = UInt8(index)
            let start = Int64(index) * 3_840
            try feed.add(Fixture.streamA, Fixture.noteOn(1, 60 + low, 80 + low), tick: start)
            try feed.add(Fixture.streamB, Fixture.noteOn(2, 67 + low, 100 + low), tick: start + 1_920)
            try feed.add(Fixture.streamB, Fixture.noteOff(2, 67 + low, 20 + low), tick: start + 2_920)
            try feed.add(Fixture.streamA, Fixture.noteOff(1, 60 + low, 10 + low), tick: start + 3_000)
        }
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        var expected: [MIDIClipItem] = []
        for index in 0..<4 {
            let low = UInt8(index)
            let start = Int64(index) * 3_840
            expected.append(.note(MIDIClipNote(channel: 1, note: 60 + low, velocity: 80 + low,
                                               releaseVelocity: 10 + low, startTicks: start,
                                               endTicks: start + 3_000)))
            expected.append(.note(MIDIClipNote(channel: 2, note: 67 + low, velocity: 100 + low,
                                               releaseVelocity: 20 + low, startTicks: start + 1_920,
                                               endTicks: start + 2_920)))
        }
        #expect(export.clip.items == expected)
        #expect(export.clip.lengthTicks == 15_360)
        let file = export.smf()
        #expect(file.bytes == StandardMIDIFile.write(export.clip).bytes)
        #expect(file.reorderedItems == 0)
        #expect(file.losses.losses == [.syntheticTempoMap: 1])
        let read = try StandardMIDIFile.read(file.bytes)
        #expect(read.clip == export.clip)
        #expect(read.clip.items == expected)
        #expect(export.droppedUMPOnly == 0 && export.unpairedOffs == 0 && export.openNotesClosed == 0)
        #expect(export.widenedNotes == 0 && !export.fidelityUnverified)
    }

    @Test func aNoteKeepsItsCaptureTicksVelocityAndReleaseVelocity() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(3, 61, 99), tick: 480)
        try feed.add(Fixture.streamA, Fixture.noteOff(3, 61, 33), tick: 1_000)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items == [.note(MIDIClipNote(channel: 3, note: 61, velocity: 99, releaseVelocity: 33,
                                                         startTicks: 480, endTicks: 1_000))])
    }

    @Test func defaultLengthIsTheNextQuarterStrictlyAfterTheLastMessageAndAtLeastOneQuarter() throws {
        let expectations: [(last: Int64, length: Int64)] = [
            (0, 15_360), (1, 15_360), (15_359, 15_360), (15_360, 30_720), (15_361, 30_720), (30_719, 30_720)]
        for (last, length) in expectations {
            var feed = try Fixture.Feed([Fixture.streamA])
            try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 100), tick: last)
            let export = try Fixture.export(feed.log, [Fixture.streamA])
            #expect(export.clip.lengthTicks == length)
            #expect(export.clip.items == [.event(ticks: last, message: .controlChange(channel: 1, controller: 7,
                                                                                         value: 100))])
        }
    }

    @Test func anExplicitLengthIsKeptAndTheOpenNoteClosesThere() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 100)
        let export = try Fixture.export(feed.log, [Fixture.streamA], length: 20_000)
        #expect(export.clip.lengthTicks == 20_000)
        #expect(export.clip.items == [.note(MIDIClipNote(channel: 1, note: 60, velocity: 64, releaseVelocity: 64,
                                                         startTicks: 100, endTicks: 20_000))])
        #expect(export.openNotesClosed == 1)
    }

    @Test func everyChannelVoiceKindBecomesAClipEventInOnsetOrder() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.controlChange(2, 7, 90), tick: 0)
        try feed.add(Fixture.streamA, Fixture.voice(0xC4, 12, nil), tick: 10)
        try feed.add(Fixture.streamA, Fixture.voice(0xE0, 0x7F, 0x7F), tick: 20)
        try feed.add(Fixture.streamA, Fixture.voice(0xD5, 77, nil), tick: 30)
        try feed.add(Fixture.streamA, Fixture.voice(0xA6, 64, 21), tick: 40)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items == [
            .event(ticks: 0, message: .controlChange(channel: 2, controller: 7, value: 90)),
            .event(ticks: 10, message: .programChange(channel: 5, program: 12)),
            .event(ticks: 20, message: .pitchBend(channel: 1, value: 0x3FFF)),
            .event(ticks: 30, message: .channelPressure(channel: 6, pressure: 77)),
            .event(ticks: 40, message: .polyphonicPressure(channel: 7, note: 64, pressure: 21))])
        #expect(export.smf().reorderedItems == 0)
    }

    @Test func anIdleStreamOfTheLogIsRefusedWithNoCapturesAfterAnotherStreamExported() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 100)
        #expect(try Fixture.export(feed.log, [Fixture.streamA]).clip.items.count == 1)
        #expect(Fixture.refusal(feed.log, [Fixture.streamB]) == .capture(.exportHasNoCaptures))
    }
}
