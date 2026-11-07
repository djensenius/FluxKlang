import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CaptureSMFExportTests {
    /// Stream `a` holds one timed note. `b` holds an unsupported capture (a capture stamped before a locate) and `c`
    /// one refused at capacity (the 4,097th unsupported capture), so both are tainted; `idle` and `other` hold nothing.
    private static func taintedFeed() throws -> Fixture.Feed {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB, Fixture.streamC, Fixture.idle,
                                     Fixture.other])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 100)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 200)
        try feed.locate(atTick: 5_000)
        for index in 0..<MIDICaptureLog.maximumUnsupported {
            try feed.add(Fixture.streamB, Fixture.controlChange(1, 7, 1), tick: Int64(index % 100))
        }
        #expect(feed.captureRefusal(Fixture.streamC, Fixture.controlChange(1, 7, 1), tick: 1)
            == .capacity(limit: MIDICaptureLog.maximumUnsupported))
        return feed
    }

    @Test func anEmptyStreamListIsRefused() throws {
        let feed = try Fixture.Feed([Fixture.streamA])
        #expect(Fixture.refusal(feed.log, []) == .capture(.exportStreamsEmpty))
    }

    @Test func selectedStreamBoundsAre64AndOneMore() throws {
        var names: [StreamID] = []
        for index in 0..<65 { names.append(try StreamID("str.s\(index)")) }
        var feed = try Fixture.Feed(Array(names.prefix(MIDICaptureLog.maximumStreams)))
        try feed.add(names[0], Fixture.noteOn(1, 60, 64), tick: 0)
        let all = Array(names.prefix(64))
        #expect(try Fixture.export(feed.log, all).clip.items.count == 1)
        #expect(Fixture.refusal(feed.log, all + [names[0]]) == .tooManyStreams(count: 65, limit: 64))
        #expect(Fixture.refusal(feed.log, all + [names[64]]) == .tooManyStreams(count: 65, limit: 64))
    }

    @Test func tooManyStreamsIsReportedBeforeADuplicate() throws {
        var names: [StreamID] = []
        for index in 0..<64 { names.append(try StreamID("str.s\(index)")) }
        let feed = try Fixture.Feed(names)
        #expect(Fixture.refusal(feed.log, names + [names[63]]) == .tooManyStreams(count: 65, limit: 64))
        #expect(Fixture.refusal(feed.log, [names[63]] + names) == .tooManyStreams(count: 65, limit: 64))
    }

    @Test func aDuplicateIsReportedBeforeAnUndeclaredStreamInEitherListOrder() throws {
        let feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        let expected = CaptureClipExportRefusal.capture(.exportStreamsDuplicate(Fixture.streamB))
        #expect(Fixture.refusal(feed.log, [Fixture.undeclared, Fixture.streamB, Fixture.streamB]) == expected)
        #expect(Fixture.refusal(feed.log, [Fixture.streamB, Fixture.streamB, Fixture.undeclared]) == expected)
    }

    @Test func anUndeclaredStreamIsReportedBeforeATaintedOneInEitherListOrder() throws {
        let log = try Self.taintedFeed().log
        let expected = CaptureClipExportRefusal.capture(.undeclaredStream(Fixture.undeclared))
        #expect(Fixture.refusal(log, [Fixture.streamB, Fixture.undeclared]) == expected)
        #expect(Fixture.refusal(log, [Fixture.undeclared, Fixture.streamB]) == expected)
    }

    @Test func taintedStreamsAreReportedInListOrderWithTheirOwnStream() throws {
        let log = try Self.taintedFeed().log
        #expect(log.taints == [Fixture.streamB: .unsupportedCapture, Fixture.streamC: .refusedAtCapacity])
        #expect(Fixture.refusal(log, [Fixture.streamB, Fixture.streamC])
            == .capture(.containsUnsupportedCapture(stream: Fixture.streamB)))
        #expect(Fixture.refusal(log, [Fixture.streamC, Fixture.streamB])
            == .capture(.captureRefusedAtCapacity(stream: Fixture.streamC)))
        #expect(Fixture.refusal(log, [Fixture.streamA, Fixture.streamC])
            == .capture(.captureRefusedAtCapacity(stream: Fixture.streamC)))
    }

    @Test func aTaintedStreamIsReportedBeforeNoCapturesAndAnUntaintedEmptyOneIsNot() throws {
        let log = try Self.taintedFeed().log
        #expect(Fixture.refusal(log, [Fixture.streamB])
            == .capture(.containsUnsupportedCapture(stream: Fixture.streamB)))
        #expect(Fixture.refusal(log, [Fixture.idle]) == .capture(.exportHasNoCaptures))
        #expect(Fixture.refusal(log, [Fixture.idle, Fixture.other]) == .capture(.exportHasNoCaptures))
        #expect(Fixture.refusal(log, [Fixture.idle], length: 0) == .capture(.exportHasNoCaptures))
        #expect(Fixture.refusal(log, [Fixture.streamC])
            == .capture(.captureRefusedAtCapacity(stream: Fixture.streamC)))
        #expect(try Fixture.export(log, [Fixture.streamA, Fixture.idle]).clip.items.count == 1)
    }

    @Test func missingMusicalTimeNamesTheFirstUntimedCaptureOfTheSelection() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB], transport: false)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 61, 64), tick: 10)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 20)
        #expect(feed.log.records.map(\.musicalTicks) == [nil, nil, nil])
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB])
            == .noMusicalTime(stream: Fixture.streamA, index: 0))
        #expect(Fixture.refusal(feed.log, [Fixture.streamB]) == .noMusicalTime(stream: Fixture.streamB, index: 1))
        try feed.anchorTransport(atFrame: 1_000)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 64), tick: 30)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 62, 64), tick: 40)
        #expect(feed.log.records.map(\.musicalTicks) == [nil, nil, nil, 30, 40])
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .noMusicalTime(stream: Fixture.streamA, index: 0))
    }

    @Test func aTimedStreamExportsWhileAnUntimedOneOfTheSameLogIsNotSelected() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB], transport: false)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 61, 64), tick: 10)
        try feed.anchorTransport(atFrame: 1_000)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 64), tick: 30)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 62, 64), tick: 40)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items == [.note(MIDIClipNote(channel: 1, note: 62, velocity: 64, releaseVelocity: 64,
                                                         startTicks: 30, endTicks: 40))])
    }

    @Test func missingMusicalTimeIsReportedBeforeALengthOutOfRangeAndBeforeNothingExportable() throws {
        var feed = try Fixture.Feed([Fixture.streamA], transport: false)
        try feed.add(Fixture.streamA, Fixture.utility, tick: 0)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: 0)
            == .noMusicalTime(stream: Fixture.streamA, index: 0))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .noMusicalTime(stream: Fixture.streamA, index: 0))
    }

    @Test func aLengthOutOfRangeIsReportedBeforeNothingExportableAndBeforeAnInvalidPacket() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.utility, tick: 0)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: 0) == .lengthOutOfRange(0))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: -5) == .lengthOutOfRange(-5))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: 1) == .nothingExportable(dropped: 1))
        try feed.add(Fixture.streamA, [0x2000_0000], tick: 5)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: MIDIClip.maximumLengthTicks + 1)
            == .lengthOutOfRange(MIDIClip.maximumLengthTicks + 1))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: 1) == .invalidChannelVoice(
            stream: Fixture.streamA, index: 1, .reservedStatus(mt: .midi1ChannelVoice, status: 0)))
    }

    @Test func recordsAreMergedByTicksThenStreamIdThenRecordIndexForEitherSelectionOrder() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamB, Fixture.controlChange(1, 7, 1), tick: 100)
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 2), tick: 100)
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 3), tick: 100)
        try feed.add(Fixture.streamB, Fixture.controlChange(1, 7, 4), tick: 50)
        let expected: [MIDIClipItem] = [
            .event(ticks: 50, message: .controlChange(channel: 1, controller: 7, value: 4)),
            .event(ticks: 100, message: .controlChange(channel: 1, controller: 7, value: 2)),
            .event(ticks: 100, message: .controlChange(channel: 1, controller: 7, value: 3)),
            .event(ticks: 100, message: .controlChange(channel: 1, controller: 7, value: 1))]
        let forward = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        let backward = try Fixture.export(feed.log, [Fixture.streamB, Fixture.streamA])
        #expect(forward.clip.items == expected)
        #expect(backward == forward)
    }

    @Test func aNoteOffOfAnEarlierStreamAtTheSameTickPairsBeforeALaterStreamsNoteOn() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 20), tick: 100)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 60, 65), tick: 100)
        try feed.add(Fixture.streamB, Fixture.noteOff(1, 60, 21), tick: 200)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.clip.items == [
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 64, releaseVelocity: 20, startTicks: 0, endTicks: 100)),
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 65, releaseVelocity: 21, startTicks: 100,
                               endTicks: 200))])
    }

    @Test func aNoteOnOfAnEarlierStreamAtTheSameTickAsALaterStreamsOffIsRefusedNotReordered() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, Fixture.noteOff(1, 60, 20), tick: 100)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 65), tick: 100)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB])
            == .noteOnWhileSounding(channel: 1, note: 60, ticks: 100, sinceTicks: 0))
    }

    @Test func aNoteEndingWhereTheNextBeginsIsWrittenWithTheOffBeforeTheOn() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 100), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 1_000)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 100), tick: 1_000)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 2_000)
        let file = try Fixture.export(feed.log, [Fixture.streamA]).smf()
        let header: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x3C, 0x00]
        let track: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x87, 0x68, 0x80, 0x3C, 0x40, 0x00, 0x90, 0x3C, 0x64,
                              0x87, 0x68, 0x80, 0x3C, 0x40, 0xE8, 0x30, 0xFF, 0x2F, 0x00]
        #expect(file.bytes == header + [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 23] + track)
        #expect(file.reorderedItems == 0)
    }

    @Test func anInferredLengthOutOfRangeIsReportedBeforeAnUndecodablePacketAndAnInRangeOneIsNot() throws {
        let longest = MIDIClip.maximumLengthTicks
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, [0x2000_0000], tick: 0)
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 100), tick: longest)
        let inferred = (longest / MusicalTime.ticksPerQuarter + 1) * MusicalTime.ticksPerQuarter
        #expect(inferred > longest)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .lengthOutOfRange(inferred))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: 1) == .invalidChannelVoice(
            stream: Fixture.streamA, index: 0, .reservedStatus(mt: .midi1ChannelVoice, status: 0)))
        var inRange = try Fixture.Feed([Fixture.streamA])
        try inRange.add(Fixture.streamA, [0x2000_0000], tick: 0)
        try inRange.add(Fixture.streamA, Fixture.controlChange(1, 7, 100), tick: 1_000)
        #expect(Fixture.refusal(inRange.log, [Fixture.streamA]) == .invalidChannelVoice(
            stream: Fixture.streamA, index: 0, .reservedStatus(mt: .midi1ChannelVoice, status: 0)))
        var late = try Fixture.Feed([Fixture.streamA])
        try late.add(Fixture.streamA, Fixture.controlChange(1, 7, 100), tick: 0)
        try late.add(Fixture.streamA, [0x2000_0000], tick: longest)
        #expect(Fixture.refusal(late.log, [Fixture.streamA]) == .lengthOutOfRange(inferred))
        #expect(Fixture.refusal(late.log, [Fixture.streamA], length: 1) == .invalidChannelVoice(
            stream: Fixture.streamA, index: 1, .reservedStatus(mt: .midi1ChannelVoice, status: 0)))
    }

    @Test func aCaptureThatIsNotMIDI1ChannelVoiceNeverExtendsTheInferredLength() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 100)
        try feed.add(Fixture.streamA, Fixture.utility, tick: 100_000)
        try feed.add(Fixture.streamB, Fixture.midi2NoteOn, tick: MIDIClip.maximumLengthTicks, endpoint: .midi2,
                     port: .midi2)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.clip.lengthTicks == MusicalTime.ticksPerQuarter)
        #expect(export.droppedUMPOnly == 2)
    }

    @Test func aSelectionWithNoMIDI1ChannelVoiceReportsNothingExportableWhenTheLengthIsInferred() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.utility, tick: MIDIClip.maximumLengthTicks)
        try feed.add(Fixture.streamB, Fixture.midi2NoteOn, tick: 5, endpoint: .midi2, port: .midi2)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB]) == .nothingExportable(dropped: 2))
    }
}
