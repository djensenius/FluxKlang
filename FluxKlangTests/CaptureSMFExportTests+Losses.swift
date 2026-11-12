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
        #expect(export.droppedUMPOnly == 3)
        #expect(export.clip.items == [.note(MIDIClipNote(channel: 1, note: 60, velocity: 64, releaseVelocity: 64,
                                                         startTicks: 0, endTicks: 50))])
        #expect(export.sysEx == [SMFSysExEvent(ticks: 20, payload: [1, 2, 3, 0])])
        #expect(export.smf().losses.losses == [.umpOnlyDropped: 3])
    }

    @Test func aSelectionWhereEveryCaptureIsDroppedRefusesNothingExportableWithTheCount() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.utility, tick: 10)
        try feed.add(Fixture.streamA, Fixture.orphanSysEx, tick: 20)
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
        #expect(export.droppedUMPOnly == 0)
        #expect(export.smf().losses.losses == [:])
    }

    @Test func anMT2OnlyTimedCaptureIsLosslessWhateverItsEndpointProtocolOrPort() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB, Fixture.streamC])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0, endpoint: .unknown)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10, endpoint: .unknown)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 61, 64), tick: 20, endpoint: .midi2, port: .midi1)
        try feed.add(Fixture.streamB, Fixture.noteOff(1, 61, 64), tick: 30, endpoint: .midi2, port: .midi1)
        try feed.add(Fixture.streamC, Fixture.noteOn(1, 62, 64), tick: 40, endpoint: .midi1, port: .midi1)
        try feed.add(Fixture.streamC, Fixture.noteOff(1, 62, 64), tick: 50, endpoint: .midi1, port: .midi1)
        for streams in [[Fixture.streamA], [Fixture.streamB], [Fixture.streamC],
                        [Fixture.streamA, Fixture.streamB, Fixture.streamC]] {
            let file = try Fixture.export(feed.log, streams).smf()
            #expect(file.losses.losses == [:])
            #expect(file.losses.lossless)
        }
        let all = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB, Fixture.streamC])
        #expect(all.clip.items.count == 3)
    }

    @Test func everyCaptureTheFileLacksIsCountedAsUMPOnlyDroppedAndTheExportIsNeverLossless() throws {
        let streams = [Fixture.streamA, Fixture.streamB, Fixture.streamC, Fixture.other]
        var feed = try Fixture.Feed(streams)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        // An OS-upscaled MIDI 1.0 note (MT 0x4 from a midi1 endpoint), a genuine MIDI 2.0 note, an orphaned SysEx 7
        // packet and a utility message: section 9.3 counts the first as lossless once written, but none is written.
        try feed.add(Fixture.streamB, Fixture.midi2NoteOn, tick: 10, endpoint: .midi1, port: .midi2)
        try feed.add(Fixture.streamC, Fixture.midi2NoteOn, tick: 20, endpoint: .midi2, port: .midi2)
        try feed.add(Fixture.other, Fixture.orphanSysEx, tick: 30)
        try feed.add(Fixture.other, Fixture.utility, tick: 40)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 50)
        let export = try Fixture.export(feed.log, streams)
        #expect(export.droppedUMPOnly == 4)
        #expect(export.clip.items.count == 1)
        let file = export.smf()
        #expect(file.losses.losses == [.umpOnlyDropped: 4])
        #expect(!file.losses.lossless)
    }

    @Test func anUnknownEndpointUMPOnlyCaptureAddsNoFidelityUnverified() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB, Fixture.streamC])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, Fixture.utility, tick: 5, endpoint: .unknown)
        try feed.add(Fixture.streamC, Fixture.midi2NoteOn, tick: 6, endpoint: .unknown, port: .midi2)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB, Fixture.streamC])
        #expect(export.droppedUMPOnly == 2)
        #expect(export.smf().losses.losses == [.umpOnlyDropped: 2])
    }

    @Test func everyLossAtOnceIsReportedAndTheBytesAreTheWritersBytes() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0, endpoint: .unknown)
        try feed.add(Fixture.streamB, Fixture.orphanSysEx, tick: 5)
        try feed.add(Fixture.streamB, Fixture.realTime, tick: 6)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        let file = export.smf()
        #expect(file.losses.losses == [.umpOnlyDropped: 2])
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
        #expect(export.smf().losses.losses == [:])
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
        #expect(first.smf().losses.losses == [.timingQuantized: 1])
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
        #expect(unchanged.timingQuantized == 0 && unchanged.smf().losses.losses == [:])
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
        #expect(unprovable.smf().losses.losses == [.timingQuantized: 1])
    }

    @Test func aCaptureWithoutTransportCarriesNoRoundTripFrame() throws {
        var feed = try Fixture.Feed([Fixture.streamA], transport: false)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 1)
        let record = try #require(feed.log.records.last)
        #expect(record.musicalTicks == nil)
        #expect(record.musicalRoundTripFrame == nil)
    }

    @Test func aCaptureWithoutTransportCarriesNoPass() throws {
        var feed = try Fixture.Feed([Fixture.streamA], transport: false)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 1)
        let record = try #require(feed.log.records.last)
        #expect(record.musicalTicks == nil && record.pass == nil)
    }

    @Test func capturesOfOneSpanAndLoopIterationShareOnePassAndNothingIsOverlaid() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 61, 64), tick: 10)
        try feed.anchorTransport(atFrame: 100, ticks: 100)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 20)
        try feed.add(Fixture.streamB, Fixture.noteOff(1, 61, 64), tick: 30)
        #expect(feed.log.records.map(\.pass) == Array(repeating: Fixture.pass(0), count: 4))
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(export.passesOverlaid == 0)
        #expect(export.smf().losses.losses == [:])
        #expect(export.smf().losses.lossless)
    }

    @Test func aLocateBeginsANewPassSoEveryCaptureAfterItIsOverlaid() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 40)
        try feed.locate(atTick: 100)
        try feed.anchorTransport(atFrame: 100, ticks: 5_000, transport: 2)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 64), tick: 10)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 62, 64), tick: 20)
        // The new transport generation after a locate is that locate's own, so it begins no second pass.
        #expect(feed.log.records.map(\.pass) == [Fixture.pass(0), Fixture.pass(0), Fixture.pass(1), Fixture.pass(1)])
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.passesOverlaid == 2)
        let file = export.smf()
        #expect(file.losses.losses == [.passesOverlaid: 2])
        #expect(!file.losses.lossless)
        #expect(file.bytes == StandardMIDIFile.write(export.clip).bytes)
    }

    @Test func aTransportRestartWithoutALocateBeginsANewPassAndALaterAnchorOfItDoesNot() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.anchorTransport(atFrame: 100, transport: 2)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10)
        try feed.anchorTransport(atFrame: 200, ticks: 50, transport: 2)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 64), tick: 10)
        #expect(feed.log.records.map(\.pass) == [Fixture.pass(0), Fixture.pass(1), Fixture.pass(1)])
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.passesOverlaid == 2)
        #expect(export.smf().losses.losses == [.passesOverlaid: 2])
    }

    @Test func eachLoopIterationIsAPassOfItsOwnInsideOneTransportSpan() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 10)
        try feed.anchorTransport(atFrame: 200, loopIteration: 1)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 20)
        try feed.anchorTransport(atFrame: 400, loopIteration: 2)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 64), tick: 30)
        #expect(feed.log.records.map(\.pass) == [Fixture.pass(0), Fixture.pass(0, 1), Fixture.pass(0, 2)])
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.passesOverlaid == 2)
        #expect(export.smf().losses.losses == [.passesOverlaid: 2])
    }

    @Test func aLaterSpanOutranksEveryLoopIterationOfAnEarlierOne() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.anchorTransport(atFrame: 100, loopIteration: 2)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.locate(atTick: 200)
        try feed.anchorTransport(atFrame: 200, transport: 2)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 5)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 64), tick: 10)
        #expect(feed.log.records.map(\.pass) == [Fixture.pass(0, 2), Fixture.pass(1), Fixture.pass(1)])
        #expect(Fixture.pass(0, 2) < Fixture.pass(1) && Fixture.pass(1) < Fixture.pass(1, 1))
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.passesOverlaid == 2)
    }

    @Test func passesOverlaidCountsTheCapturesOutsideTheEarliestPassNotThePasses() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        func controller(_ value: UInt8, tick: Int64) throws {
            try feed.add(Fixture.streamA, Fixture.controlChange(1, 7, value), tick: tick)
        }
        try controller(1, tick: 0)
        try controller(2, tick: 10)
        try feed.locate(atTick: 100)
        try feed.anchorTransport(atFrame: 100, ticks: 1_000, transport: 2)
        for value in 1...3 { try controller(UInt8(value), tick: Int64(value)) }
        try feed.anchorTransport(atFrame: 200, transport: 3)
        try controller(7, tick: 5)
        try feed.anchorTransport(atFrame: 300, transport: 3, loopIteration: 1)
        try controller(8, tick: 5)
        try controller(9, tick: 6)
        let (first, second, third, fourth) = (Fixture.pass(0), Fixture.pass(1), Fixture.pass(2), Fixture.pass(2, 1))
        #expect(feed.log.records.map(\.pass) == [first, first, second, second, second, third, fourth, fourth])
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.passesOverlaid == 6)
        #expect(export.smf().losses.losses == [.passesOverlaid: 6])
    }

    /// A clock restart continues its pass, and the new generation's anchors begin again at loop iteration 0, so the
    /// log carries the iteration the transport anchor ended in (a restart in the middle of a loop that wrapped without
    /// an anchor is beyond what the log sees).
    @Test func aClockRestartContinuesItsPassAndCarriesTheLoopIterationItEndedIn() throws {
        typealias Capture = MIDICaptureFixture
        let keys = Capture.keysA
        var plain = try Capture.log([keys])
        try plain.observe(anchor: Capture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        try Capture.capture(&plain, keys, Fixture.controlChange(1, 7, 1), host: 2_412_000_000)
        try Capture.restartExample09(&plain)
        try Capture.capture(&plain, keys, Fixture.controlChange(1, 7, 2), host: 2_496_000_000)
        #expect(plain.records.map(\.pass) == [Fixture.pass(0), Fixture.pass(0)])
        let single = try Fixture.export(plain, [keys])
        #expect(single.passesOverlaid == 0 && single.smf().losses.lossless)

        var looped = try Capture.log([keys])
        func play(_ value: UInt8, at host: UInt64) throws {
            try Capture.capture(&looped, keys, Fixture.controlChange(1, 7, value), host: host,
                                microsPerQuarter: 500_000)
        }
        try looped.observe(anchor: Capture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        try play(1, at: 2_412_000_000)
        try looped.observe(anchor: Capture.anchor(1, frame: 192_000, host: 2_496_000_000, transport: 1,
                                                  loopIteration: 1))
        try play(2, at: 2_497_000_000)
        try looped.observe(Capture.restart(2, host: 2_500_000_000), stream: nil, nominalRate: 48_000)
        try looped.observe(anchor: Capture.anchor(2, frame: 0, host: 2_500_000_000, transport: 2, ticks: 100))
        try play(3, at: 2_501_000_000)
        try looped.observe(anchor: Capture.anchor(2, frame: 20_000, host: 2_510_000_000, transport: 2,
                                                  loopIteration: 1))
        try play(4, at: 2_511_000_000)
        let (start, wrapped, further) = (Fixture.pass(0), Fixture.pass(0, 1), Fixture.pass(0, 2))
        #expect(looped.records.map(\.pass) == [start, wrapped, wrapped, further])
        let export = try Fixture.export(looped, [keys])
        #expect(export.passesOverlaid == 3)
        #expect(export.smf().losses.losses == [.passesOverlaid: 3])
    }

    /// A locate begins the next span at loop iteration 0, also right after a clock restart that carried an iteration
    /// over (§9.3's `(P + 1, 0)`): the capture after both is one span above every iteration of the span before.
    @Test func aLocateAfterAClockRestartBeginsTheNextSpanAtLoopIterationZero() throws {
        typealias Capture = MIDICaptureFixture
        let keys = Capture.keysA
        var log = try Capture.log([keys])
        func play(_ value: UInt8, at host: UInt64) throws {
            try Capture.capture(&log, keys, Fixture.controlChange(1, 7, value), host: host,
                                microsPerQuarter: 500_000)
        }
        try log.observe(anchor: Capture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        try log.observe(anchor: Capture.anchor(1, frame: 192_000, host: 2_496_000_000, transport: 1,
                                               loopIteration: 1))
        try play(1, at: 2_497_000_000)
        try log.observe(Capture.restart(2, host: 2_500_000_000), stream: nil, nominalRate: 48_000)
        try log.observe(Capture.discontinuity(.locate, generation: 2, host: 2_505_000_000), stream: nil)
        try log.observe(anchor: Capture.anchor(2, frame: 20_000, host: 2_510_000_000, transport: 2))
        try play(2, at: 2_511_000_000)
        #expect(log.records.map(\.pass) == [Fixture.pass(0, 1), Fixture.pass(1)])
        let export = try Fixture.export(log, [keys])
        #expect(export.passesOverlaid == 1)
        #expect(export.smf().losses.losses == [.passesOverlaid: 1])
    }

    /// A refused locate, restart or anchor leaves the log exactly as it was, its pass base included: the base is
    /// written only after the last check. The latest transport anchor is in loop iteration 1, so a restart's carry
    /// shows as well as a locate's new span, and the refused anchors name another transport generation.
    @Test func aRefusedObservationLeavesTheLogAndItsPassBaseAsItWas() throws {
        typealias Capture = MIDICaptureFixture
        let keys = Capture.keysA
        var log = try Capture.log([keys])
        try log.observe(anchor: Capture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1))
        try log.observe(anchor: Capture.anchor(1, frame: 192_000, host: 2_496_000_000, transport: 1,
                                               loopIteration: 1))
        try Capture.capture(&log, keys, Fixture.controlChange(1, 7, 1), host: 2_497_000_000)
        let before = log
        let early = HostStamp(ticks: 2_495_999_999)
        let predates = MIDICaptureRefusal.discontinuityPredatesCutoff(host: early,
                                                                      cutoff: HostStamp(ticks: 2_496_000_000))
        func refused(_ expected: MIDICaptureRefusal, sourceLocation: SourceLocation = #_sourceLocation,
                     by observation: (inout MIDICaptureLog) throws -> Void) {
            #expect(Capture.refusal { try observation(&log) } == expected, sourceLocation: sourceLocation)
            #expect(log == before, sourceLocation: sourceLocation)
        }
        func locating(at host: UInt64?) -> (inout MIDICaptureLog) throws -> Void {
            return { try $0.observe(Capture.discontinuity(.locate, host: host), stream: nil) }
        }
        func restarting(_ generation: UInt64 = 2, at host: UInt64? = 2_500_000_000,
                        rate: Int? = 48_000) -> (inout MIDICaptureLog) throws -> Void {
            return { try $0.observe(Capture.restart(generation, host: host), stream: nil, nominalRate: rate) }
        }
        func anchoring(_ generation: Int, frame: Int64, host: UInt64,
                       ticks: Int64 = 0) -> (inout MIDICaptureLog) throws -> Void {
            return {
                try $0.observe(anchor: Capture.anchor(generation, frame: frame, host: host, transport: 2,
                                                      ticks: ticks))
            }
        }
        refused(.discontinuityNeedsHost, by: locating(at: nil))
        refused(predates, by: locating(at: early.ticks))
        refused(.discontinuityNeedsHost, by: restarting(at: nil))
        refused(.staleGeneration, by: restarting(3))
        refused(predates, by: restarting(at: early.ticks))
        refused(.restartNeedsRate, by: restarting(rate: nil))
        refused(.invalidRate(47_999), by: restarting(rate: 47_999))
        refused(.negativeMusicalTicks, by: anchoring(1, frame: 194_000, host: 2_497_000_000, ticks: -1))
        refused(.staleGeneration, by: anchoring(2, frame: 0, host: 2_500_000_000))
        refused(.anchorDisagrees, by: anchoring(1, frame: 192_000, host: 2_496_000_000))
        refused(.anchorDisagrees, by: anchoring(1, frame: 200_000, host: 2_497_000_000))
        // The next valid restart carries the loop iteration once, so no refusal moved the pass base on the way.
        try log.observe(Capture.restart(2, host: 2_500_000_000), stream: nil, nominalRate: 48_000)
        try log.observe(anchor: Capture.anchor(2, frame: 0, host: 2_500_000_000, transport: 2))
        try Capture.capture(&log, keys, Fixture.controlChange(1, 7, 2), host: 2_501_000_000)
        #expect(log.records.map(\.pass) == [Fixture.pass(0, 1), Fixture.pass(0, 1)])
    }

    /// Example 03 declares `{"passesOverlaid": 2}`: iteration 1's capture and the one after the locate lie outside
    /// iteration 0, which holds the capture delivered after the wrap anchor.
    @Test func exampleThreeDeclaresItsTwoOverlaidCaptures() throws {
        let log = try MIDICaptureFixture.example03()
        #expect(log.records.map(\.pass) == [Fixture.pass(0), Fixture.pass(0, 1), Fixture.pass(1)])
        let export = try Fixture.export(log, [MIDICaptureFixture.keysIn])
        #expect(export.passesOverlaid == 2 && export.timingQuantized == 0)
        let file = export.smf()
        #expect(file.losses.losses == [.passesOverlaid: 2])
        #expect(!file.losses.lossless)
    }

    @Test func passesOverlaidFollowsTheSelectionAndCountsCapturesTheFileDoesNotHold() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB, Fixture.streamC])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 10)
        try feed.anchorTransport(atFrame: 100, transport: 2)
        try feed.add(Fixture.streamB, Fixture.noteOn(1, 62, 64), tick: 10)
        try feed.add(Fixture.streamB, Fixture.noteOff(1, 62, 64), tick: 20)
        try feed.add(Fixture.streamB, Fixture.utility, tick: 21)
        try feed.add(Fixture.streamC, Fixture.midi2NoteOn, tick: 22, endpoint: .midi2, port: .midi2)
        let earlier = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(earlier.passesOverlaid == 0 && earlier.smf().losses.lossless)
        let later = try Fixture.export(feed.log, [Fixture.streamB])
        #expect(later.passesOverlaid == 0 && later.smf().losses.losses == [.umpOnlyDropped: 1])
        let both = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        #expect(both.passesOverlaid == 3 && both.droppedUMPOnly == 1)
        #expect(both.smf().losses.losses == [.passesOverlaid: 3, .umpOnlyDropped: 1])
        let all = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB, Fixture.streamC])
        #expect(all.passesOverlaid == 4 && all.droppedUMPOnly == 2)
        #expect(all.smf().losses.losses == [.passesOverlaid: 4, .umpOnlyDropped: 2])
    }

    @Test func passesOverlaidSitsBesideTheOtherLossesInOneReport() throws {
        var feed = try Fixture.Feed([Fixture.streamA, Fixture.streamB], microsPerQuarter: 500_000)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 64), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 60, 64), tick: 25)
        try feed.anchorTransport(atFrame: 100, transport: 2)
        try feed.add(Fixture.streamB, [0x2190_3E64], tick: 1)
        try feed.add(Fixture.streamB, Fixture.utility, tick: 3)
        let export = try Fixture.export(feed.log, [Fixture.streamA, Fixture.streamB])
        let file = export.smf()
        #expect(file.losses.losses == [.umpOnlyDropped: 1, .groupsFlattened: 1, .passesOverlaid: 2,
                                       .timingQuantized: 1])
        #expect(!file.losses.lossless)
    }
}
