import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CaptureSMFExportTests {
    @Test func capturesThatAreNotMIDI1ChannelVoiceAreCountedAsDroppedNeverTranslated() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.utility, tick: 10)
        try feed.add(Fixture.streamA, Fixture.sysEx, tick: 20)
        try feed.add(Fixture.streamA, Fixture.realTime, tick: 30)
        try feed.add(Fixture.streamB, Fixture.midi2NoteOn, tick: 40, endpoint: .midi2, port: .midi2)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 50)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.droppedUMPOnly == 4)
        #expect(export.clip.items == [.note(MIDIClipNote(channel: 1, note: 60, velocity: 64, releaseVelocity: 64,
                                                         startTicks: 0, endTicks: 50))])
        #expect(export.smf().losses.losses == [.syntheticTempoMap: 1, .umpOnlyDropped: 4])
        #expect(!export.fidelityUnverified)
    }

    @Test func aSelectionWhereEveryCaptureIsDroppedRefusesNothingExportableWithTheCount() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.utility, tick: 10)
        try feed.add(Fixture.streamA, Fixture.sysEx, tick: 20)
        try feed.add(Fixture.streamB, Fixture.midi2NoteOn, tick: 30, endpoint: .midi2, port: .midi2)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB]) == .nothingExportable(dropped: 3))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .nothingExportable(dropped: 2))
    }

    @Test func onlyCapturesOfTheSelectedStreamsAreExportedOrCounted() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, Fixture.utility, tick: 10, endpoint: .unknown)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 20)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.droppedUMPOnly == 0 && !export.fidelityUnverified)
        #expect(export.smf().losses.losses == [.syntheticTempoMap: 1])
    }

    @Test func anUnknownEndpointProtocolMarksTheExportUnverifiedAndItStillSucceeds() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0, endpoint: .unknown)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10, endpoint: .unknown)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.fidelityUnverified)
        #expect(export.clip.items.count == 1)
        #expect(export.smf().losses.losses == [.syntheticTempoMap: 1, .fidelityUnverified: 1])
    }

    @Test func anOSTranslatedCaptureMarksTheExportUnverified() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0, endpoint: .midi2, port: .midi1)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10, endpoint: .midi2, port: .midi1)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.fidelityUnverified)
        #expect(export.smf().losses.losses == [.syntheticTempoMap: 1, .fidelityUnverified: 1])
    }

    @Test func aVerifiedNativeMIDI1CaptureLeavesTheExportVerified() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0, endpoint: .midi1, port: .midi1)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(!export.fidelityUnverified)
    }

    @Test func aDroppedUnverifiedCaptureStillMarksTheSelectionUnverified() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, Fixture.utility, tick: 5, endpoint: .unknown)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.droppedUMPOnly == 1 && export.fidelityUnverified)
        #expect(export.smf().losses.losses == [.syntheticTempoMap: 1, .umpOnlyDropped: 1, .fidelityUnverified: 1])
    }

    @Test func everyLossAtOnceIsReportedAndTheBytesAreTheWritersBytes() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0, endpoint: .unknown)
        try feed.add(Fixture.streamB, Fixture.sysEx, tick: 5)
        try feed.add(Fixture.streamB, Fixture.realTime, tick: 6)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        let file = export.smf()
        #expect(file.losses.losses == [.syntheticTempoMap: 1, .umpOnlyDropped: 2, .fidelityUnverified: 1])
        #expect(!file.losses.lossless)
        #expect(file.bytes == StandardMIDIFile.write(export.clip).bytes)
        #expect(file.reorderedItems == StandardMIDIFile.write(export.clip).reorderedItems)
    }

    @Test func unpairedOffsOpenNotesAndWidenedNotesAreReportedOnTheExportNotAsSMFLosses() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 40, 1), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 50, 64), tick: 10)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 50, 64), tick: 10)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 20)
        try feed.add(Fixture.streamA, Fixture.noteOn(2, 61, 64), tick: 30)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.unpairedOffs == 1 && export.widenedNotes == 1 && export.openNotesClosed == 2)
        #expect(export.smf().losses.losses == [.syntheticTempoMap: 1])
        #expect(export.clip.items == [
            .note(MIDIClipNote(channel: 1, note: 50, velocity: 64, releaseVelocity: 64, startTicks: 10,
                               endTicks: 11)),
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 64, releaseVelocity: 64, startTicks: 20,
                               endTicks: 15_360)),
            .note(MIDIClipNote(channel: 2, note: 61, velocity: 64, releaseVelocity: 64, startTicks: 30,
                               endTicks: 15_360))])
    }

    @Test func aReservedStatusInAnMT2PacketIsRefusedWithItsStreamAndRecordIndex() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 61, 64), tick: 5)
        try feed.add(Fixture.streamB, [0x2000_0000], tick: 10)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB])
            == .invalidChannelVoice(stream: Fixture.streamB, index: 2,
                                    .reservedStatus(mt: .midi1ChannelVoice, status: 0x00)))
    }

    @Test func aCaptureOfAnotherStreamIsNotDecodedAtAll() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, [0x2000_0000], tick: 10)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items.count == 1)
    }
}
