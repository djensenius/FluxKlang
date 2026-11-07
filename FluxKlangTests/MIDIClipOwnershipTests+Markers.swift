import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClipOwnershipTests {
    /// A ledger where `input` pressed note 60 on route 1, then again on route 2, and route 1 was lost: one release
    /// marker sits before the held press on route 2.
    private static func markedLedger(for input: MIDIInputID, noteCapacity: Int = 1024) throws -> MIDINoteLedger {
        var ledger = try Self.ledger(noteCapacity: noteCapacity)
        try Self.play(Self.on(60), input: input, to: [route1], in: &ledger)
        try Self.play(Self.on(60), input: input, to: [route2], in: &ledger)
        _ = ledger.routeLost(route1)
        return ledger
    }

    private static func idleItems() -> [MIDIClipItem] {
        [note(0, quarter)]
    }

    @Test
    func aClipInputWithReleaseMarkersInTheLedgerIsRefusedWithItsOwnReasonAndNothingChanges() throws {
        let ledger = try Self.markedLedger(for: Self.clipID)
        #expect(ledger.releaseMarkers.map(\.input) == [Self.clipID])
        var host = MIDIClipHost(ledger: ledger)
        let before = host
        #expect(Self.refusal { try Self.addClip(Self.idleItems(), id: Self.clipID, in: &host) }
            == .inputHoldsReleaseMarkers(Self.clipID))
        #expect(host == before && host.boundInputs.isEmpty)
        #expect(host.ledger.notes == ledger.notes && host.ledger.releaseMarkers == ledger.releaseMarkers)
        #expect(host.ledger.pedalHolds == ledger.pedalHolds)
    }

    @Test
    func aMarkerOnAnotherInputDoesNotBlockAddAndTheClipsStopLeavesItNoEntries() throws {
        var ledger = try Self.markedLedger(for: Self.otherID)
        try Self.play(Self.on(72), input: Self.thirdID, to: [Self.route1], in: &ledger)
        let others = ledger.notes
        let markers = ledger.releaseMarkers
        #expect(markers.map(\.input) == [Self.otherID])
        var host = MIDIClipHost(ledger: ledger)
        try Self.addClip([Self.note(0, 2 * Self.quarter)], id: Self.clipID, in: &host)
        _ = try Self.render(&host, to: 12_000)
        #expect(host.ownedNotes(of: Self.clipID).count == 1)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60))])
        #expect(host.ownedNotes(of: Self.clipID).isEmpty)
        #expect(host.ledger.notes == others && host.ledger.releaseMarkers == markers)
    }

    @Test
    func aMarkersOwnNoteOffConsumesItAndTheInputIsAcceptedOnceItsNotesAreReleased() throws {
        var host = MIDIClipHost(ledger: try Self.markedLedger(for: Self.clipID))
        let toRoute2 = try Self.routing(Self.clipID, to: [Self.route2])
        let off = MIDIPerformanceEvent(input: Self.clipID, message: Self.off(60))
        // The first Note Off belongs to the lost press: it sends nothing and consumes the marker.
        #expect(try host.routeOther([off], routing: toRoute2).isEmpty)
        #expect(host.ledger.releaseMarkers.isEmpty && host.ownedNotes(of: Self.clipID).count == 1)
        #expect(Self.refusal { try Self.addClip(Self.idleItems(), id: Self.clipID, in: &host) }
            == .inputHoldsLedgerNotes(Self.clipID))
        #expect(try host.routeOther([off], routing: toRoute2).count == 1)
        #expect(host.ledger.notes.isEmpty)
        try Self.addClip(Self.idleItems(), id: Self.clipID, in: &host)
        #expect(host.boundInputs == [Self.clipID])
    }

    @Test
    func aMarkedInputIsReportedBeforeItsHeldNotesAndPedals() throws {
        var ledger = try Self.markedLedger(for: Self.clipID)
        try Self.play(.controlChange(channel: 1, controller: 64, value: 127), input: Self.clipID, in: &ledger)
        #expect(!ledger.notes.isEmpty && !ledger.pedalHolds.isEmpty && !ledger.releaseMarkers.isEmpty)
        var host = MIDIClipHost(ledger: ledger)
        let before = host
        #expect(Self.refusal { try Self.addClip(Self.idleItems(), id: Self.clipID, in: &host) }
            == .inputHoldsReleaseMarkers(Self.clipID))
        #expect(host == before)
    }

    @Test
    func aFullHostReportsTheLimitBeforeMarkersNotesAndPedals() throws {
        var ledger = try Self.markedLedger(for: Self.clipID)
        try Self.play(.controlChange(channel: 1, controller: 64, value: 127), input: Self.clipID, in: &ledger)
        var marked = MIDIClipHost(ledger: ledger)
        var pedalOnly = MIDIClipHost(ledger: try Self.ledger())
        try Self.play(.controlChange(channel: 1, controller: 64, value: 127), input: Self.otherID, in: &pedalOnly)
        for index in 0..<MIDIClipHost.maximumClips {
            try Self.addClip(Self.idleItems(), id: MIDIInputID(UInt32(100 + index)), in: &marked)
            try Self.addClip(Self.idleItems(), id: MIDIInputID(UInt32(100 + index)), in: &pedalOnly)
        }
        let beforeMarked = marked
        let beforePedal = pedalOnly
        #expect(Self.refusal { try Self.addClip(Self.idleItems(), id: Self.clipID, in: &marked) }
            == .clipLimitReached(limit: 64))
        #expect(Self.refusal { try Self.addClip(Self.idleItems(), id: Self.otherID, in: &pedalOnly) }
            == .clipLimitReached(limit: 64))
        #expect(marked == beforeMarked && pedalOnly == beforePedal)
    }

    @Test
    func aBoundClipWithSoundingNotesReportsTheDuplicateBeforeTheHeldNotes() throws {
        var host = try Self.host([Self.note(0, 2 * Self.quarter)])
        _ = try Self.render(&host, to: 12_000)
        #expect(!host.ownedNotes(of: Self.clipID).isEmpty)
        let before = host
        #expect(Self.refusal { try Self.addClip(Self.idleItems(), id: Self.clipID, in: &host) }
            == .inputAlreadyBound(Self.clipID))
        #expect(host == before)
    }

    @Test
    func aStopOfTheLargestPossibleSoundingSetIsAcceptedAndLeavesTheClipInputNoEntries() throws {
        let channels = 16
        let pitches = 128
        let items = (0..<(channels * pitches)).map { index in
            MIDIClipItem.note(MIDIClipNote(channel: UInt8(1 + index / pitches), note: UInt8(index % pitches),
                                           velocity: 100, releaseVelocity: 64, startTicks: Int64(index),
                                           endTicks: 20_000))
        }
        var host = try Self.host(items, length: 20_000, ledger: try Self.ledger(noteCapacity: 4096))
        let played = try Self.render(&host, from: 0, to: 4_000)
        #expect(played.routedEventCount == 2048 && played.refusals.isEmpty)
        #expect(host.ownedNotes(of: Self.clipID).count == 2048)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.routedEventCount == 2048 && stopped.outputs.count == 2048 && stopped.refusals.isEmpty)
        #expect(host.ownedNotes(of: Self.clipID).isEmpty && host.ledger.notes.isEmpty)
        // One more note of a sounding channel and pitch would overlap: the clip refuses it, so 2,048 is the maximum.
        let extra = Self.note(10, 30, pitch: 0)
        #expect(throws: MIDIClipRefusal.self) { try MIDIClip.make(lengthTicks: 20_000, items: items + [extra]) }
    }
}
