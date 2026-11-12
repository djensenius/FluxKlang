import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #584 SMF2a: SysEx7 (MT 0x3) captures written as SMF `F0 ... F7` events.
extension CaptureSMFExportTests {
    /// Helpers of the SysEx tests, nested so no name is shared with another test file of the module.
    enum SysExFixture {
        /// The words of one SysEx7 packet.
        static func words(_ status: UMPSysEx7Status, _ bytes: [UInt8], group: UInt8 = 0) throws -> [UInt32] {
            try UMPSysEx7Packet(group: UMPGroup(group), status: status, bytes: bytes).packet.words
        }

        /// The bytes of the track chunk of a file the writer made (the header is 14 bytes, the chunk header 8).
        static func track(_ file: [UInt8]) throws -> [UInt8] {
            try #require(file.count > 22)
            return Array(file[22...])
        }

        /// `00 F0 <size> <payload> F7`: the event at the start of the track.
        static func event(_ payload: [UInt8]) -> [UInt8] {
            [0x00, 0xF0] + StandardMIDIFile.quantity(UInt32(payload.count + 1)) + payload + [0xF7]
        }

        /// A delta to the end of a one-quarter clip from tick 0, then End of Track.
        static let endOfQuarter: [UInt8] = [0xF8, 0x00, 0xFF, 0x2F, 0x00]
    }

    @Test func aCompleteMessageOfEveryPacketSizeBecomesOneSysExEventAndNothingIsCounted() throws {
        for size in [0, 1, 6, 7, 12, 13] {
            let payload = (0..<size).map { UInt8($0 + 1) }
            var feed = try Fixture.Feed([Fixture.streamA])
            for packet in try UMPSysEx7Packet.packets(group: UMPGroup(0), payload: payload) {
                try feed.add(Fixture.streamA, packet.packet.words, tick: 0)
            }
            let export = try Fixture.export(feed.log, [Fixture.streamA])
            #expect(export.sysEx == [SMFSysExEvent(ticks: 0, payload: payload)])
            #expect(export.clip.items.isEmpty && export.droppedUMPOnly == 0)
            let file = export.smf()
            #expect(file.losses.losses == [:] && file.losses.lossless)
            #expect(try SysExFixture.track(file.bytes) == SysExFixture.event(payload) + SysExFixture.endOfQuarter)
        }
    }

    @Test func theSizeOfTheEventIsAVariableLengthQuantityOfThePayloadPlusOne() throws {
        for (size, quantity) in [(126, [UInt8(0x7F)]), (127, [0x81, 0x00])] {
            let payload = (0..<size).map { UInt8($0 % 100) }
            var feed = try Fixture.Feed([Fixture.streamA])
            for packet in try UMPSysEx7Packet.packets(group: UMPGroup(0), payload: payload) {
                try feed.add(Fixture.streamA, packet.packet.words, tick: 0)
            }
            let track = try SysExFixture.track(try Fixture.export(feed.log, [Fixture.streamA]).smf().bytes)
            #expect(track == [0x00, 0xF0] + quantity + payload + [0xF7] + SysExFixture.endOfQuarter)
        }
    }

    @Test func aMessageSitsAtTheTickOfItsFirstPacket() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, try SysExFixture.words(.start, [1, 2, 3, 4, 5, 6]), tick: 100)
        try feed.add(Fixture.streamA, try SysExFixture.words(.continue, [7, 8, 9, 10, 11, 12]), tick: 200)
        try feed.add(Fixture.streamA, try SysExFixture.words(.end, [13, 14]), tick: 300)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.sysEx == [SMFSysExEvent(ticks: 100, payload: Array(1...14))])
        #expect(export.clip.lengthTicks == 15_360)
        let read = try StandardMIDIFile.read(export.smf().bytes)
        #expect(read.clip == export.clip)
        #expect(read.report.ignoredSysEx == [.message: 1])
    }

    @Test func groupsOfOneStreamAssembleSeparatelyAndOtherStreamsToo() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, try SysExFixture.words(.start, [1, 2], group: 0), tick: 10)
        try feed.add(Fixture.streamA, try SysExFixture.words(.start, [3, 4], group: 1), tick: 20)
        try feed.add(Fixture.streamB, try SysExFixture.words(.start, [5, 6], group: 0), tick: 30)
        try feed.add(Fixture.streamA, try SysExFixture.words(.end, [7], group: 0), tick: 40)
        try feed.add(Fixture.streamB, try SysExFixture.words(.end, [8], group: 0), tick: 50)
        try feed.add(Fixture.streamA, try SysExFixture.words(.end, [9], group: 1), tick: 60)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.sysEx == [SMFSysExEvent(ticks: 10, payload: [1, 2, 7]),
                                 SMFSysExEvent(ticks: 20, payload: [3, 4, 9]),
                                 SMFSysExEvent(ticks: 30, payload: [5, 6, 8])])
        #expect(export.droppedUMPOnly == 0)
        // The group-1 packets sit outside the lowest group seen; nothing else is lost.
        #expect(export.smf().losses.losses == [.groupsFlattened: 2])
        // The same group of another stream is another message: B's end finds no message open in A's group.
        var split = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try split.add(Fixture.streamA, try SysExFixture.words(.start, [1]), tick: 10)
        try split.add(Fixture.streamB, try SysExFixture.words(.end, [2]), tick: 20)
        #expect(Fixture.refusal(split.log, [Fixture.streamA, Fixture.streamB]) == .nothingExportable(dropped: 2))
    }

    @Test func aStartOrACompleteAbortsTheOpenMessageAndEachDroppedPacketCountsOnce() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, try SysExFixture.words(.start, [1]), tick: 10)
        try feed.add(Fixture.streamA, try SysExFixture.words(.continue, [2]), tick: 20)
        try feed.add(Fixture.streamA, try SysExFixture.words(.start, [3]), tick: 30)
        try feed.add(Fixture.streamA, try SysExFixture.words(.end, [4]), tick: 40)
        try feed.add(Fixture.streamA, try SysExFixture.words(.start, [5]), tick: 50)
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [6]), tick: 60)
        // The complete closed the aborted message for good: this end is an orphan.
        try feed.add(Fixture.streamA, try SysExFixture.words(.end, [7]), tick: 70)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.sysEx == [SMFSysExEvent(ticks: 30, payload: [3, 4]), SMFSysExEvent(ticks: 60, payload: [6])])
        #expect(export.droppedUMPOnly == 4)
        #expect(export.smf().losses.losses == [.umpOnlyDropped: 4])
    }

    @Test func anOrphanedContinueOrEndAndAMessageLeftOpenAreDroppedPerPacket() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, try SysExFixture.words(.continue, [1]), tick: 10)
        try feed.add(Fixture.streamA, try SysExFixture.words(.end, [2]), tick: 20)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .nothingExportable(dropped: 2))
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 30)
        try feed.add(Fixture.streamA, try SysExFixture.words(.start, [3]), tick: 40)
        try feed.add(Fixture.streamA, try SysExFixture.words(.continue, [4]), tick: 50)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.sysEx.isEmpty && export.droppedUMPOnly == 4)
        #expect(export.smf().losses.losses == [.umpOnlyDropped: 4])
    }

    @Test func aBadSysEx7PacketIsRefusedWithItsStreamAndRecordIndex() throws {
        let cases: [([UInt32], UMPRefusal)] = [
            ([0x3001_8000, 0], .reservedBitsSet(mt: .data64, status: 0)),
            ([0x3040_0000, 0], .reservedStatus(mt: .data64, status: 4)),
            ([0x3007_0000, 0], .valueOutOfRange(field: .sysEx7ByteCount, value: 7)),
            ([0x3000_0100, 0], .reservedBitsSet(mt: .data64, status: 0))]
        for (words, refusal) in cases {
            var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
            try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
            try feed.add(Fixture.streamB, words, tick: 5)
            #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB])
                == .invalidSysEx7(stream: Fixture.streamB, index: 1, refusal))
        }
    }

    @Test func theFirstDefectInCaptureOrderWinsBetweenChannelVoiceAndSysEx7() throws {
        let badVoice: [UInt32] = [0x2000_0000]
        let badSysEx: [UInt32] = [0x3001_8000, 0]
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, badVoice, tick: 10)
        try feed.add(Fixture.streamB, badSysEx, tick: 0)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA, Fixture.streamB])
            == .invalidChannelVoice(stream: Fixture.streamA, index: 0,
                                    .reservedStatus(mt: .midi1ChannelVoice, status: 0x00)))
        var reversed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try reversed.add(Fixture.streamB, badSysEx, tick: 10)
        try reversed.add(Fixture.streamA, badVoice, tick: 0)
        #expect(Fixture.refusal(reversed.log, [Fixture.streamA, Fixture.streamB])
            == .invalidSysEx7(stream: Fixture.streamB, index: 0, .reservedBitsSet(mt: .data64, status: 0)))
        // A bad packet of an unselected stream is not decoded.
        var other = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try other.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try other.add(Fixture.streamB, badSysEx, tick: 5)
        #expect(try Fixture.export(other.log, [Fixture.streamA]).clip.items.count == 1)
    }

    @Test func atOneTickNoteOffsComeThenSysExThenEverythingElseInExactBytes() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 100), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 80), tick: 100)
        try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 90), tick: 100)
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [1, 2]), tick: 100)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 100)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 62, 64), tick: 200)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        let expected: [UInt8] = [0x00, 0x90, 0x3C, 0x64,
                                 0x64, 0x80, 0x3C, 0x40, 0x00, 0xF0, 0x03, 0x01, 0x02, 0xF7,
                                 0x00, 0x90, 0x3E, 0x50, 0x00, 0xB0, 0x07, 0x5A,
                                 0x64, 0x80, 0x3E, 0x40, 0xF6, 0x38, 0xFF, 0x2F, 0x00]
        let file = export.smf()
        #expect(file.bytes == [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x3C, 0x00,
                               0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, UInt8(expected.count)] + expected)
        let read = try StandardMIDIFile.read(file.bytes)
        #expect(read.clip == export.clip)
        #expect(read.report.ignoredSysEx == [.message: 1])
        #expect(file.reorderedItems == 0)
    }

    @Test func sysExEventsMergeByTicksThenStreamIdThenRecordIndex() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamB, try SysExFixture.words(.complete, [1]), tick: 50)
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [2]), tick: 50)
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [3]), tick: 50)
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [4]), tick: 10)
        let export = try Fixture.export(feed.log, [Fixture.streamB, Fixture.streamA])
        #expect(export.sysEx.map(\.payload) == [[4], [2], [3], [1]])
    }

    @Test func aSysExAtOrAfterTheClipLengthIsRefusedAndOneBeforeItIsNot() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [1]), tick: 999)
        #expect(try Fixture.export(feed.log, [Fixture.streamA], length: 1_000).sysEx.count == 1)
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [2]), tick: 1_000)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA], length: 1_000)
            == .ticksOutOfRange(ticks: 1_000, lengthTicks: 1_000))
    }

    @Test func sysExEventsCountTowardTheItemCap() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        for index in 0..<(MIDIClip.maximumItems - 1) {
            try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: Int64(index))
        }
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [1]), tick: 0)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items.count == 16_383 && export.sysEx.count == 1)
        try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [2]), tick: 1)
        #expect(Fixture.refusal(feed.log, [Fixture.streamA]) == .tooManyItems(count: 16_385, limit: 16_384))
    }

    @Test func theDefaultLengthCoversTheLastSysExCaptureDeliveredOrNot() throws {
        let lengths: [(tick: Int64, length: Int64)] = [(0, 15_360), (15_359, 15_360), (15_360, 30_720)]
        for (tick, length) in lengths {
            var feed = try Fixture.Feed([Fixture.streamA])
            try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: 100)
            try feed.add(Fixture.streamA, try SysExFixture.words(.complete, [1]), tick: tick)
            #expect(try Fixture.export(feed.log, [Fixture.streamA]).clip.lengthTicks == length)
            var orphan = try Fixture.Feed([Fixture.streamA])
            try orphan.add(Fixture.streamA, Fixture.controlChange(1, 7, 1), tick: 100)
            try orphan.add(Fixture.streamA, try SysExFixture.words(.end, [1]), tick: tick)
            let export = try Fixture.export(orphan.log, [Fixture.streamA])
            #expect(export.clip.lengthTicks == length && export.droppedUMPOnly == 1)
        }
    }

    @Test func aWriterWithNoSysExWritesTheClipBytesOfTheClipOverload() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(StandardMIDIFile.write(export.clip, sysEx: []) == StandardMIDIFile.write(export.clip))
        #expect(export.sysEx.isEmpty)
    }
}
