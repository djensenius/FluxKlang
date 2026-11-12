import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CaptureSMFExportTests {
    private static func feedWithControlChange(at tick: Int64) throws -> Fixture.Feed {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 100), tick: tick)
        return feed
    }

    @Test func explicitLengthBoundsAreOneAndTheMaximumAndRefuseZeroAndOneMore() throws {
        let log = try Self.feedWithControlChange(at: 0).log
        #expect(try Fixture.export(log, [Fixture.streamA], length: 1).clip.lengthTicks == 1)
        let longest = MIDIClip.maximumLengthTicks
        #expect(try Fixture.export(log, [Fixture.streamA], length: longest).clip.lengthTicks == longest)
        #expect(Fixture.refusal(log, [Fixture.streamA], length: 0) == .lengthOutOfRange(0))
        #expect(Fixture.refusal(log, [Fixture.streamA], length: longest + 1) == .lengthOutOfRange(longest + 1))
        #expect(Fixture.refusal(log, [Fixture.streamA], length: Int64.min) == .lengthOutOfRange(Int64.min))
    }

    @Test func defaultLengthBoundsAreTheMaximumAndTheQuarterBeyondIt() throws {
        let longest = MIDIClip.maximumLengthTicks
        let atLimit = try Self.feedWithControlChange(at: longest - 1).log
        #expect(try Fixture.export(atLimit, [Fixture.streamA]).clip.lengthTicks == longest)
        let beyond = try Self.feedWithControlChange(at: longest).log
        #expect(Fixture.refusal(beyond, [Fixture.streamA]) == .lengthOutOfRange(longest + MusicalTime.ticksPerQuarter))
        #expect(Fixture.refusal(beyond, [Fixture.streamA], length: longest)
            == .clip(.eventOutsideClip(item: 0, ticks: longest)))
    }

    @Test func aMessageBeyondAnExplicitLengthIsRefusedAndOneAtTheLengthIsLeftToTheClip() throws {
        let inside = try Self.feedWithControlChange(at: 999).log
        #expect(try Fixture.export(inside, [Fixture.streamA], length: 1_000).clip.lengthTicks == 1_000)
        let atEnd = try Self.feedWithControlChange(at: 1_000).log
        #expect(Fixture.refusal(atEnd, [Fixture.streamA], length: 1_000)
            == .clip(.eventOutsideClip(item: 0, ticks: 1_000)))
        let beyond = try Self.feedWithControlChange(at: 1_001).log
        #expect(Fixture.refusal(beyond, [Fixture.streamA], length: 1_000)
            == .ticksOutOfRange(ticks: 1_001, lengthTicks: 1_000))
    }

    @Test func aNoteOpenedAtTheLengthIsWidenedPastItAndTheClipRefusesWithItsSpan() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 1_000)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: 1_000)
            == .clip(.invalidNoteSpan(item: 0, startTicks: 1_000, endTicks: 1_001)))
    }

    @Test func aClipRefusalIsWrappedWithItsOwnItemPayload() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10)
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 64, 127), tick: 20)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .clip(.unsupportedMessage(item: 1)))
    }

    @Test func aWidenedZeroLengthNoteOverlappingTheNextOnIsRefusedByTheClipWithBothItems() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 10)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 65), tick: 10)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 20)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .clip(.overlappingNotes(first: 0, second: 1)))
    }

    @Test func aDoubleNoteOnAtOneTickInTheLogIsRefusedWithItsChannelNoteAndTicks() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(7, 33, 64), tick: 40)
        try feed.add(Fixture.streamA, Fixture.noteOn(7, 33, 65), tick: 40)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA])
            == .noteOnWhileSounding(channel: 7, note: 33, ticks: 40, sinceTicks: 40))
    }

    @Test func aDoubleNoteOnAtALaterTickInTheLogRetriggersTheNote() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(7, 33, 64), tick: 40)
        try feed.add(Fixture.streamA, Fixture.noteOn(7, 33, 65), tick: 90)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items == [
            .note(MIDIClipNote(channel: 7, note: 33, velocity: 64, releaseVelocity: 64, startTicks: 40, endTicks: 90)),
            .note(MIDIClipNote(channel: 7, note: 33, velocity: 65, releaseVelocity: 64, startTicks: 90,
                               endTicks: 15_360))])
        #expect(export.retriggeredNotes == 1 && export.openNotesClosed == 1)
        #expect(export.smf().losses.losses == [:])
    }

    @Test func exportItemBoundsAre16384AndOneMore() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        for index in 0..<MIDIClip.maximumItems {
            try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: Int64(index))
        }
        #expect(try Fixture.export(feed.log, [Fixture.streamA]).clip.items.count == 16_384)
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: 16_384)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .tooManyItems(count: 16_385, limit: 16_384))
    }

    @Test func aFullLogOf65536CapturesExportsItsItemsAndCountsEveryDroppedOne() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        for index in 0..<MIDIClip.maximumItems {
            try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: Int64(index))
        }
        for index in 0..<(MIDICaptureLog.maximumCaptures - MIDIClip.maximumItems) {
            try feed.add(Fixture.streamA, Fixture.utility, tick: Int64(index))
        }
        #expect(feed.log.records.count == MIDICaptureLog.maximumCaptures)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items.count == 16_384 && export.droppedUMPOnly == 49_152)
        #expect(export.smf().losses.losses == [.umpOnlyDropped: 49_152])
        #expect(feed.captureRefusal(Fixture.streamB, Fixture.utility, tick: 0) == .capacity(limit: 65_536))
        #expect(Fixture.refusal(feed.log, [Fixture.streamB])
            == .capture(.captureRefusedAtCapacity(stream: Fixture.streamB)))
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB])
            == .capture(.captureRefusedAtCapacity(stream: Fixture.streamB)))
    }

    @Test func aFullLogWithOneItemTooManyRefusesInsteadOfTruncating() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        for index in 0...MIDIClip.maximumItems {
            try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: Int64(index))
        }
        for index in 0..<(MIDICaptureLog.maximumCaptures - MIDIClip.maximumItems - 1) {
            try feed.add(Fixture.streamA, Fixture.utility, tick: Int64(index))
        }
        #expect(feed.log.records.count == MIDICaptureLog.maximumCaptures)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .tooManyItems(count: 16_385, limit: 16_384))
    }

    /// `Int64.max / ticksPerQuarter` quarters of 15,360 ticks end at 9,223,372,036,854,773,760.
    private static func defaultLengthRefusal(lastTicks: Int64) throws -> CaptureClipExportRefusal? {
        var feed = try Fixture.Feed([Fixture.streamA], transport: false)
        try feed.anchorTransport(atFrame: 1, ticks: lastTicks)
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 100), tick: 0)
        #expect(feed.log.records.map(\.musicalTicks) == [lastTicks])
        return Fixture.refusal(feed.log, [Fixture.streamA])
    }

    @Test func aDefaultLengthWhoseQuarterProductOverflowsIsRefusedAsInt64MaxAndOneBelowAsItsLength() throws {
        let boundary: Int64 = 9_223_372_036_854_773_760
        #expect(try Self.defaultLengthRefusal(lastTicks: boundary - 1) == .lengthOutOfRange(boundary))
        #expect(try Self.defaultLengthRefusal(lastTicks: boundary) == .lengthOutOfRange(Int64.max))
        #expect(try Self.defaultLengthRefusal(lastTicks: Int64.max) == .lengthOutOfRange(Int64.max))
    }
}
