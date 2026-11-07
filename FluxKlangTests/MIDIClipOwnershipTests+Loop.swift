import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClipOwnershipTests {
    @Test
    func aLoopWrapIsRefusedLeavingLedgerAndPlaybackUnchangedThenStopReleasesTheClipsNotes() throws {
        var host = try Self.host([Self.note(0, 2 * Self.quarter, release: 9)])
        try Self.play(Self.on(72), input: Self.otherID, in: &host)
        _ = try Self.render(&host, to: 12_000)
        let before = host
        let wrapped = try Self.clock(loopIteration: 1)
        #expect(Self.refusal { try Self.render(&host, from: 12_000, to: 20_000, clock: wrapped) }
            == .clip(.loopWrapRequiresStop(expected: 0, got: 1)))
        #expect(host == before)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60, velocity: 9))])
        #expect(host.ownedNotes(of: Self.clipID).isEmpty)
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == Self.entries(of: Self.otherID, in: before.ledger))
    }

    @Test
    func aClipLoopCutsTheNoteAtTheLoopEndAndTheLedgerHoldsOneEntryAtEachBoundary() throws {
        var host = try Self.host([Self.note(0, 2 * Self.quarter)], loop: (0, Self.quarter))
        let first = try Self.render(&host, to: 12_000)
        #expect(first.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.on(60))])
        #expect(host.ownedNotes(of: Self.clipID).count == 1)
        // The loop end is frame 24_000: the cut Note Off comes before the next pass's Note On.
        let wrap = try Self.render(&host, from: 12_000, to: 24_001)
        #expect(wrap.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60)),
                                 MIDIRoutedOutput(route: Self.route1, message: Self.on(60))])
        #expect(wrap.unownedNoteCount == 0 && wrap.refusals.isEmpty)
        #expect(host.ownedNotes(of: Self.clipID).count == 1)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60))])
        #expect(host.ledger.notes.isEmpty)
    }

    @Test
    func aLoopedClipStoppedMidPassLeavesADroneAndRestartsCleanlyAfterStop() throws {
        var host = try Self.host([Self.note(0, Self.quarter, pitch: 62)], loop: (0, 2 * Self.quarter))
        try Self.play(Self.on(40), input: Self.otherID, to: [Self.route2], in: &host)
        let drone = Self.entries(of: Self.otherID, in: host.ledger)
        _ = try Self.render(&host, to: 60_000)
        _ = try Self.render(&host, from: 60_000, to: 72_000)
        #expect(host.ownedNotes(of: Self.clipID).count == 1)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(62))])
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == drone && host.ledger.notes.count == 1)
        let again = try Self.render(&host, to: 100)
        #expect(again.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.on(62))])
    }

    @Test
    func aNoteCollapsedOntoOneFrameHasItsOffAfterItsOwnOnWhileOtherOffsStillComeFirst() throws {
        // At 60_000 microseconds per quarter a quarter is 2_880 frames, so the note at ticks 15_360...15_362
        // collapses onto frame 2_880 together with the Off of the note that ends at tick 15_360: that Off comes
        // first, the collapsed note's own Off stays after its On.
        let fast = [(Int64(0), Int64(60_000))]
        let items = [Self.note(0, 15_360, pitch: 62), Self.note(15_360, 15_362, pitch: 60)]
        var host = try Self.host(items)
        let report = try Self.render(&host, to: 3_000, clock: Self.clock(segments: fast))
        #expect(report.outputs.map(\.message) == [Self.on(62), Self.off(62), Self.on(60), Self.off(60)])
        #expect(report.unownedNoteCount == 0 && report.refusals.isEmpty && host.ledger.notes.isEmpty)
    }
}
