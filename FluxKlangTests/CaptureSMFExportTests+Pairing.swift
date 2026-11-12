import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CaptureSMFExportTests {
    @Test func pairingMatchesEachChannelAndNoteAndKeepsNotesAtTheirOnsetPosition() throws {
        let events = [
            Fixture.timed(0, .noteOn(channel: 1, note: 60, velocity: 70)),
            Fixture.timed(10, .noteOn(channel: 2, note: 60, velocity: 71)),
            Fixture.timed(20, .controlChange(channel: 1, controller: 7, value: 9)),
            Fixture.timed(30, .noteOn(channel: 1, note: 61, velocity: 72)),
            Fixture.timed(40, .noteOff(channel: 2, note: 60, velocity: 5)),
            Fixture.timed(50, .noteOff(channel: 1, note: 61, velocity: 6)),
            Fixture.timed(60, .noteOff(channel: 1, note: 60, velocity: 7))]
        let pairing = try CaptureNotePairing.pair(events, lengthTicks: 100)
        #expect(pairing.items == [
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 70, releaseVelocity: 7, startTicks: 0, endTicks: 60)),
            .note(MIDIClipNote(channel: 2, note: 60, velocity: 71, releaseVelocity: 5, startTicks: 10, endTicks: 40)),
            .event(ticks: 20, message: .controlChange(channel: 1, controller: 7, value: 9)),
            .note(MIDIClipNote(channel: 1, note: 61, velocity: 72, releaseVelocity: 6, startTicks: 30, endTicks: 50))])
        #expect(pairing.unpairedOffs == 0 && pairing.openNotesClosed == 0 && pairing.widenedNotes == 0)
    }

    @Test func aNoteOnOfVelocityZeroClosesTheNoteWithReleaseVelocity64() throws {
        let direct = try CaptureNotePairing.pair([
            Fixture.timed(5, .noteOn(channel: 4, note: 50, velocity: 90)),
            Fixture.timed(25, .noteOn(channel: 4, note: 50, velocity: 0))], lengthTicks: 100)
        #expect(direct.items == [.note(MIDIClipNote(channel: 4, note: 50, velocity: 90, releaseVelocity: 64,
                                                    startTicks: 5, endTicks: 25))])
        #expect(direct.unpairedOffs == 0 && direct.openNotesClosed == 0)
        let lone = try CaptureNotePairing.pair([Fixture.timed(5, .noteOn(channel: 4, note: 50, velocity: 0))],
                                               lengthTicks: 100)
        #expect(lone.items.isEmpty && lone.unpairedOffs == 1)
    }

    @Test func aCapturedVelocityZeroNoteOnClosesLikeANoteOffAt64WhileANoteOffKeepsItsVelocity() throws {
        var feed = try Fixture.Feed([Fixture.streamA])
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 90), tick: 0)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 60, 0), tick: 100)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 62, 91), tick: 200)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 62, 0), tick: 300)
        try feed.add(Fixture.streamA, Fixture.noteOn(1, 64, 92), tick: 400)
        try feed.add(Fixture.streamA, Fixture.noteOff(1, 64, 33), tick: 500)
        let export = try Fixture.export(feed.log, [Fixture.streamA])
        #expect(export.clip.items == [
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 90, releaseVelocity: 64, startTicks: 0,
                               endTicks: 100)),
            .note(MIDIClipNote(channel: 1, note: 62, velocity: 91, releaseVelocity: 0, startTicks: 200,
                               endTicks: 300)),
            .note(MIDIClipNote(channel: 1, note: 64, velocity: 92, releaseVelocity: 33, startTicks: 400,
                               endTicks: 500))])
        #expect(export.unpairedOffs == 0)
    }

    @Test func anOffWithNoOpenNoteIsCountedAndDroppedIncludingASecondOff() throws {
        let pairing = try CaptureNotePairing.pair([
            Fixture.timed(0, .noteOff(channel: 1, note: 60, velocity: 1)),
            Fixture.timed(10, .noteOn(channel: 1, note: 60, velocity: 70)),
            Fixture.timed(20, .noteOff(channel: 1, note: 60, velocity: 2)),
            Fixture.timed(30, .noteOff(channel: 1, note: 60, velocity: 3)),
            Fixture.timed(40, .noteOff(channel: 2, note: 60, velocity: 4))], lengthTicks: 100)
        #expect(pairing.items == [.note(MIDIClipNote(channel: 1, note: 60, velocity: 70, releaseVelocity: 2,
                                                     startTicks: 10, endTicks: 20))])
        #expect(pairing.unpairedOffs == 3)
    }

    @Test func aNoteStillOpenClosesAtTheLengthInItemOrderAndIsCounted() throws {
        let pairing = try CaptureNotePairing.pair([
            Fixture.timed(10, .noteOn(channel: 2, note: 70, velocity: 80)),
            Fixture.timed(20, .noteOn(channel: 1, note: 71, velocity: 81)),
            Fixture.timed(30, .noteOn(channel: 1, note: 72, velocity: 82)),
            Fixture.timed(40, .noteOff(channel: 1, note: 71, velocity: 9))], lengthTicks: 500)
        #expect(pairing.items == [
            .note(MIDIClipNote(channel: 2, note: 70, velocity: 80, releaseVelocity: 64, startTicks: 10,
                               endTicks: 500)),
            .note(MIDIClipNote(channel: 1, note: 71, velocity: 81, releaseVelocity: 9, startTicks: 20,
                               endTicks: 40)),
            .note(MIDIClipNote(channel: 1, note: 72, velocity: 82, releaseVelocity: 64, startTicks: 30,
                               endTicks: 500))])
        #expect(pairing.openNotesClosed == 2 && pairing.widenedNotes == 0 && pairing.unpairedOffs == 0)
    }

    @Test func aZeroLengthNoteIsWidenedByOneTickAndCounted() throws {
        let pairing = try CaptureNotePairing.pair([
            Fixture.timed(50, .noteOn(channel: 3, note: 40, velocity: 60)),
            Fixture.timed(50, .noteOff(channel: 3, note: 40, velocity: 11))], lengthTicks: 100)
        #expect(pairing.items == [.note(MIDIClipNote(channel: 3, note: 40, velocity: 60, releaseVelocity: 11,
                                                     startTicks: 50, endTicks: 51))])
        #expect(pairing.widenedNotes == 1 && pairing.openNotesClosed == 0)
        let atLength = try CaptureNotePairing.pair([Fixture.timed(100, .noteOn(channel: 3, note: 40, velocity: 60))],
                                                   lengthTicks: 100)
        #expect(atLength.items == [.note(MIDIClipNote(channel: 3, note: 40, velocity: 60, releaseVelocity: 64,
                                                      startTicks: 100, endTicks: 101))])
        #expect(atLength.widenedNotes == 1 && atLength.openNotesClosed == 1)
    }

    @Test func wideningAtTheLargestTickIsRefusedInsteadOfWrapping() {
        let top = Int64.max
        let events = [Fixture.timed(top, .noteOn(channel: 1, note: 60, velocity: 64)),
                      Fixture.timed(top, .noteOff(channel: 1, note: 60, velocity: 64))]
        #expect(Fixture.pairingRefusal(events, length: top) == .ticksOutOfRange(ticks: top, lengthTicks: top))
    }

    @Test func aSecondNoteOnAtTheTickTheNoteBeganIsRefusedWithItsExactPayload() {
        let events = [Fixture.timed(300, .noteOn(channel: 5, note: 61, velocity: 70)),
                      Fixture.timed(300, .noteOn(channel: 5, note: 61, velocity: 71))]
        #expect(Fixture.pairingRefusal(events, length: 1_000)
            == .noteOnWhileSounding(channel: 5, note: 61, ticks: 300, sinceTicks: 300))
        let released = events + [Fixture.timed(800, .noteOff(channel: 5, note: 61, velocity: 0))]
        #expect(Fixture.pairingRefusal(released, length: 1_000)
            == .noteOnWhileSounding(channel: 5, note: 61, ticks: 300, sinceTicks: 300))
    }

    @Test func aNoteOnAtALaterTickRetriggersTheSoundingNote() throws {
        let events = [Fixture.timed(300, .noteOn(channel: 5, note: 70, velocity: 70)),
                      Fixture.timed(700, .noteOn(channel: 5, note: 70, velocity: 71)),
                      Fixture.timed(800, .noteOff(channel: 5, note: 70, velocity: 9))]
        let pairing = try CaptureNotePairing.pair(events, lengthTicks: 1_000)
        #expect(pairing.items == [
            .note(MIDIClipNote(channel: 5, note: 70, velocity: 70, releaseVelocity: 64, startTicks: 300,
                               endTicks: 700)),
            .note(MIDIClipNote(channel: 5, note: 70, velocity: 71, releaseVelocity: 9, startTicks: 700,
                               endTicks: 800))])
        #expect(pairing.retriggeredNotes == 1)
        #expect(pairing.unpairedOffs == 0 && pairing.openNotesClosed == 0 && pairing.widenedNotes == 0)
    }

    @Test func aChainOfNoteOnsRetriggersEachTimeAndTheLastNoteStaysOpen() throws {
        let events = [Fixture.timed(100, .noteOn(channel: 1, note: 60, velocity: 10)),
                      Fixture.timed(200, .noteOn(channel: 1, note: 60, velocity: 20)),
                      Fixture.timed(300, .noteOn(channel: 1, note: 60, velocity: 30))]
        let pairing = try CaptureNotePairing.pair(events, lengthTicks: 1_000)
        #expect(pairing.items == [
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 10, releaseVelocity: 64, startTicks: 100,
                               endTicks: 200)),
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 20, releaseVelocity: 64, startTicks: 200,
                               endTicks: 300)),
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 30, releaseVelocity: 64, startTicks: 300,
                               endTicks: 1_000))])
        #expect(pairing.retriggeredNotes == 2 && pairing.openNotesClosed == 1)
    }

    @Test func aRetriggerLeavesAnotherOpenKeyAlone() throws {
        let events = [Fixture.timed(0, .noteOn(channel: 1, note: 60, velocity: 10)),
                      Fixture.timed(10, .noteOn(channel: 1, note: 61, velocity: 11)),
                      Fixture.timed(20, .noteOn(channel: 1, note: 60, velocity: 12)),
                      Fixture.timed(30, .noteOff(channel: 1, note: 61, velocity: 5)),
                      Fixture.timed(40, .noteOff(channel: 1, note: 60, velocity: 6))]
        let pairing = try CaptureNotePairing.pair(events, lengthTicks: 100)
        #expect(pairing.items == [
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 10, releaseVelocity: 64, startTicks: 0, endTicks: 20)),
            .note(MIDIClipNote(channel: 1, note: 61, velocity: 11, releaseVelocity: 5, startTicks: 10, endTicks: 30)),
            .note(MIDIClipNote(channel: 1, note: 60, velocity: 12, releaseVelocity: 6, startTicks: 20,
                               endTicks: 40))])
        #expect(pairing.retriggeredNotes == 1 && pairing.openNotesClosed == 0 && pairing.unpairedOffs == 0)
    }

    @Test func pairingTickBoundsAreZeroThroughTheLengthAndRefuseOneBeyondEither() throws {
        let inside = [Fixture.timed(0, .controlChange(channel: 1, controller: 7, value: 1)),
                      Fixture.timed(1_000, .controlChange(channel: 1, controller: 7, value: 2))]
        #expect(try CaptureNotePairing.pair(inside, lengthTicks: 1_000).items.count == 2)
        let below = [Fixture.timed(-1, .controlChange(channel: 1, controller: 7, value: 1))]
        #expect(Fixture.pairingRefusal(below, length: 1_000) == .ticksOutOfRange(ticks: -1, lengthTicks: 1_000))
        let above = [Fixture.timed(1_001, .controlChange(channel: 1, controller: 7, value: 1))]
        #expect(Fixture.pairingRefusal(above, length: 1_000) == .ticksOutOfRange(ticks: 1_001, lengthTicks: 1_000))
    }

    @Test func pairingItemCountBoundsAre16384And16385() throws {
        let message = MIDI1Semantic.controlChange(channel: 1, controller: 7, value: 1)
        let full = (0..<MIDIClip.maximumItems).map { Fixture.timed(Int64($0), message) }
        let pairing = try CaptureNotePairing.pair(full, lengthTicks: 20_000)
        #expect(pairing.items.count == 16_384)
        let over = (0...MIDIClip.maximumItems).map { Fixture.timed(Int64($0), message) }
        #expect(Fixture.pairingRefusal(over, length: 20_000) == .tooManyItems(count: 16_385, limit: 16_384))
    }

    @Test func pairing65536MessagesCountsEveryDroppedOffAndStaysWithinTheItemBound() throws {
        let change = MIDI1Semantic.controlChange(channel: 1, controller: 7, value: 1)
        var events: [CaptureTimedMessage] = []
        for index in 0..<16_384 { events.append(Fixture.timed(Int64(index), change)) }
        for index in 0..<49_152 {
            events.append(Fixture.timed(20_000 + Int64(index), .noteOff(channel: 1, note: 60, velocity: 1)))
        }
        #expect(events.count == MIDICaptureLog.maximumCaptures)
        let pairing = try CaptureNotePairing.pair(events, lengthTicks: 80_000)
        #expect(pairing.items.count == 16_384 && pairing.unpairedOffs == 49_152)
    }

    @Test func noteOnWhileSoundingIsReportedBeforeTooManyItems() {
        let change = MIDI1Semantic.controlChange(channel: 1, controller: 7, value: 1)
        var events = (0..<MIDIClip.maximumItems).map { Fixture.timed(Int64($0), change) }
        events.append(Fixture.timed(20_000, .noteOn(channel: 9, note: 12, velocity: 5)))
        events.append(Fixture.timed(20_000, .noteOn(channel: 9, note: 12, velocity: 6)))
        #expect(Fixture.pairingRefusal(events, length: 30_000)
            == .noteOnWhileSounding(channel: 9, note: 12, ticks: 20_000, sinceTicks: 20_000))
    }

    @Test func ticksOutOfRangeIsReportedBeforeANoteOnWhileSounding() {
        let events = [Fixture.timed(0, .noteOn(channel: 1, note: 60, velocity: 64)),
                      Fixture.timed(10, .noteOn(channel: 1, note: 60, velocity: 65)),
                      Fixture.timed(2_000, .controlChange(channel: 1, controller: 7, value: 1))]
        #expect(Fixture.pairingRefusal(events, length: 1_000) == .ticksOutOfRange(ticks: 2_000, lengthTicks: 1_000))
    }
}
