import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClipOwnershipTests {
    /// Two sounding clip notes (60 and 64) at frame 36_000 and a drone of another input, before any rebind.
    private static func rebindFixture() throws -> MIDIClipHost {
        var host = MIDIClipHost(ledger: try Self.ledger())
        try Self.play(Self.on(72), input: Self.otherID, in: &host)
        try Self.addClip([Self.note(0, 2 * Self.quarter), Self.note(Self.quarter, 3 * Self.quarter,
                                                                    pitch: 64, release: 7)],
                         id: Self.clipID, in: &host)
        _ = try Self.render(&host, to: 36_000)
        return host
    }

    private static func slower() throws -> (next: MIDIClipGenerations, clock: MusicalClockMap) {
        let next = try Self.generations(sample: 2, map: 2)
        return (next, try Self.clock(next, frame: 36_000, ticks: 23_040, segments: [(0, 1_000_000)]))
    }

    @Test
    func rebindLeavesTheLedgerAloneAndStopThenReleasesExactlyTheNotesThatSounded() throws {
        var host = try Self.rebindFixture()
        let before = host.ledger
        let clipBefore = host.ownedNotes(of: Self.clipID)
        #expect(clipBefore.map(\.note) == [60, 64])
        let (next, clock) = try Self.slower()
        try host.rebind(input: Self.clipID, clock: clock, current: next, atFrame: 36_000)
        #expect(host.ledger == before && host.ownedNotes(of: Self.clipID) == clipBefore)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60)),
                                    MIDIRoutedOutput(route: Self.route1, message: Self.off(64, velocity: 7))])
        #expect(host.ownedNotes(of: Self.clipID).isEmpty)
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == Self.entries(of: Self.otherID, in: before))
    }

    @Test
    func renderingAfterARebindReleasesTheNotesAtTheNewMapFramesThroughTheLedger() throws {
        var host = try Self.rebindFixture()
        let (next, clock) = try Self.slower()
        try host.rebind(input: Self.clipID, clock: clock, current: next, atFrame: 36_000)
        let rest = try Self.render(&host, from: 36_000, to: 200_000, clock: clock, current: next)
        #expect(rest.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60)),
                                 MIDIRoutedOutput(route: Self.route1, message: Self.off(64, velocity: 7))])
        #expect(rest.unownedNoteCount == 0 && rest.refusals.isEmpty)
        #expect(host.ownedNotes(of: Self.clipID).isEmpty && host.ledger.notes.map(\.input) == [Self.otherID])
    }

    @Test
    func aRefusedRebindChangesNeitherPlaybackNorLedger() throws {
        var host = try Self.rebindFixture()
        let before = host
        let next = try Self.generations(map: 2)
        let revised = try Self.clock(next)
        #expect(Self.refusal { try host.rebind(input: Self.clipID, clock: revised, current: next, atFrame: 35_000) }
            == .clip(.rebindCursorMismatch(expected: 36_000, frame: 35_000)))
        let moved = try Self.generations(transport: 2)
        #expect(Self.refusal {
            try host.rebind(input: Self.clipID, clock: Self.clock(moved), current: moved, atFrame: 36_000)
        } == .clip(.transportChangedRequiresStop(expected: .initial, got: moved.transport)))
        #expect(host == before)
        var fresh = try Self.host([Self.note(0, Self.quarter)])
        let pristine = fresh
        #expect(Self.refusal { try fresh.rebind(input: Self.clipID, clock: revised, current: next, atFrame: 0) }
            == .clip(.rebindWithoutRender))
        #expect(fresh == pristine)
        // The refused clip still stops cleanly.
        #expect(try host.stop(input: Self.clipID).outputs.count == 2)
    }
}
