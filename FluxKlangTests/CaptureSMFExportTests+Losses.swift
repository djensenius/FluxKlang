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

    /// At 500,000 microseconds per quarter and 48 kHz one tick is 1.5625 frames: frame 1 is tick 1 and maps back to
    /// frame 2, frame 3 is tick 2 and maps back to frame 3, frame 25 is tick 16 and maps back to frame 25. Every
    /// count lives in this one test, whose mutants all change the count or the round trip it reads.
    @Test func timingQuantizedCountsExactlyTheSelectedCapturesWhoseFrameChangesAndReachesTheLossReport() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB], microsPerQuarter: 500_000)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 1)
        let firstRecord = try #require(feed.log.records.last)
        #expect(firstRecord.musicalTicks == 1)
        #expect(firstRecord.musicalRoundTripFrame == 2)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 3)
        let secondRecord = try #require(feed.log.records.last)
        #expect(secondRecord.musicalTicks == 2)
        #expect(secondRecord.musicalRoundTripFrame == 3)
        let first = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(first.timingQuantized == 1)
        #expect(first.smf().losses.losses == [.syntheticTempoMap: 1, .timingQuantized: 1])
        #expect(first.smf().bytes == StandardMIDIFile.write(first.clip).bytes)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 61, 64), tick: 4)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 61, 64), tick: 25)
        let exactRecord = try #require(feed.log.records.last)
        #expect(exactRecord.musicalTicks == 16)
        #expect(exactRecord.musicalRoundTripFrame == 25)
        try feed.add(Fixture.streamA, Fixture.utility, tick: 1)
        try feed.add(Fixture.streamB, Fixture.midi2NoteOn, tick: 7, endpoint: .midi2, port: .midi2)
        let onlyA = try Fixture.export(feed.log, [Fixture.streamA])
        let both = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(onlyA.droppedUMPOnly == 1 && both.droppedUMPOnly == 2)
        #expect(onlyA.timingQuantized == 3)
        #expect(both.timingQuantized == 4)
        #expect(both.smf().losses.losses[.timingQuantized] == 4)
        var exact = try Fixture.Feed([Fixture.streamA], microsPerQuarter: 500_000)
        try exact.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try exact.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 25)
        let unchanged = try Fixture.export(exact.log, [Fixture.streamA])
        #expect(unchanged.timingQuantized == 0 && unchanged.smf().losses.losses == [.syntheticTempoMap: 1])
        var oneToOne = try Fixture.Feed([Fixture.streamA])
        try oneToOne.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 1)
        let plainRecord = try #require(oneToOne.log.records.last)
        #expect(plainRecord.musicalRoundTripFrame == plainRecord.sample.frame)
        let plain = try Fixture.export(oneToOne.log, [Fixture.streamA])
        #expect(plain.timingQuantized == 0 && plain.smf().losses.losses[.timingQuantized] == nil)
        // A capture at frame Int64.max maps to tick 1 and back to Int64.max + 1: the map-back overflows, so the
        // round trip is nil and can never equal the frame. The capture one frame earlier is exact.
        var wide = try Fixture.Feed([Fixture.streamA], microsPerQuarter: 500_000, unanchored: true)
        try wide.anchorTransport(atFrame: Int64.max - 1, host: Fixture.baseHost)
        try wide.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: 0)
        let atAnchor = try #require(wide.log.records.last)
        #expect(atAnchor.musicalRoundTripFrame == atAnchor.sample.frame)
        try wide.add(Fixture.streamA, Fixture.controlChange(1, 7, 2), tick: 1)
        let overflowed = try #require(wide.log.records.last)
        #expect(overflowed.sample.frame == Int64.max && overflowed.musicalTicks == 1)
        #expect(overflowed.musicalRoundTripFrame == nil)
        let unprovable = try Fixture.export(wide.log, [Fixture.streamA])
        #expect(unprovable.timingQuantized == 1)
        #expect(unprovable.smf().losses.losses == [.syntheticTempoMap: 1, .timingQuantized: 1])
    }

    @Test func aCaptureWithoutTransportCarriesNoRoundTripFrame() throws {
        var feed = try Fixture.Feed([Fixture.streamA], transport: false)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 1)
        let record = try #require(feed.log.records.last)
        #expect(record.musicalTicks == nil)
        #expect(record.musicalRoundTripFrame == nil)
    }
}
