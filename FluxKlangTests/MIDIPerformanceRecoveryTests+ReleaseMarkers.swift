import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Copilot round 2 (PR #343): a key-down press that loses every layer to a route loss or a route-scoped panic leaves a
/// release marker at its place in its key's release FIFO, so the Note Off that belongs to it sends nothing instead of
/// ending a newer press of the same key.
extension MIDIPerformanceRecoveryTests {
    /// Keys' key 60 went to piano, then to strings, and piano was lost: a marker sits before the strings press.
    static func markedBeforeStrings() throws -> MIDINoteLedger {
        var ledger = MIDINoteLedger()
        _ = try ledger.route(Fixture.on(60), routing: Fixture.routing(Fixture.rule(Fixture.piano)))
        _ = try ledger.route(Fixture.on(60), routing: Fixture.routing(Fixture.rule(Fixture.strings)))
        _ = ledger.routeLost(Fixture.piano)
        return ledger
    }

    @Test
    func routeLossLeavesReleaseMarker() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        _ = try ledger.route(Fixture.on(60), routing: piano)
        _ = try ledger.route(Fixture.on(60), routing: strings)
        #expect(ledger.routeLost(Fixture.piano).notes.map(\.note) == [60])
        // The first Note Off belongs to the lost press: nothing is sent and strings keeps sounding.
        #expect(try ledger.route(Fixture.off(60), routing: strings).isEmpty)
        #expect(ledger.notes.map(\.route) == [Fixture.strings])
        #expect(ledger.notes.allSatisfy { $0.keyDown })
        #expect(try ledger.route(Fixture.off(60), routing: strings) == [Fixture.sentOff(Fixture.strings, 60)])
        #expect(ledger.notes.isEmpty)
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: strings)
    }

    @Test
    func routeScopedPanicLeavesReleaseMarker() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        _ = try ledger.route(Fixture.on(60), routing: piano)
        _ = try ledger.route(Fixture.on(60), routing: strings)
        #expect(ledger.panic(.route(Fixture.piano), allNotesAndSoundOff: false) == [Fixture.sentOff(Fixture.piano, 60)])
        // The marker sends nothing, not even in a panic.
        #expect(ledger.panicPlan(.route(Fixture.piano)).isEmpty)
        #expect(try ledger.route(Fixture.off(60), routing: strings).isEmpty)
        #expect(ledger.notes.map(\.route) == [Fixture.strings])
        #expect(try ledger.route(Fixture.off(60), routing: strings) == [Fixture.sentOff(Fixture.strings, 60)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.panic().isEmpty)
    }

    @Test
    func releaseMarkersCountTowardNoteCapacity() throws {
        let policy = try #require(MIDINoteLedgerPolicy(noteCapacity: 3))
        var ledger = MIDINoteLedger(policy: policy)
        let octaves = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, transpose: 12))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        // A lost press is one marker whatever its layer count: two instances become one entry.
        _ = try ledger.route(Fixture.on(60), routing: octaves)
        _ = ledger.routeLost(Fixture.piano)
        // N: the marker and two notes fill the three entries. N + 1 is refused whole and changes nothing.
        #expect(try Fixture.play([Fixture.on(62), Fixture.on(64)], on: &ledger, routing: strings)
            == [Fixture.sentOn(Fixture.strings, 62), Fixture.sentOn(Fixture.strings, 64)])
        Fixture.expectRefused(Fixture.on(65), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 65), in: ledger,
                              routing: strings)
        // The Note Off that consumes the marker frees its entry.
        #expect(try ledger.route(Fixture.off(60), routing: strings).isEmpty)
        #expect(try ledger.route(Fixture.on(65), routing: strings) == [Fixture.sentOn(Fixture.strings, 65)])
        Fixture.expectRefused(Fixture.on(67), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 67), in: ledger,
                              routing: strings)
    }

    @Test
    func resetsClearReleaseMarkers() throws {
        let marked = try Self.markedBeforeStrings()
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        let unowned = MIDIPerformanceRefusal.unownedNote(input: Fixture.keys, channel: 1, note: 60)
        // Another input's loss, or another route's loss or panic, keeps the marker: the next Note Off sends nothing.
        var kept = marked
        #expect(kept.inputLost(Fixture.pads).isEmpty)
        #expect(kept.routeLost(Fixture.bass).notes.isEmpty)
        #expect(kept.panic(.route(Fixture.bass)).isEmpty)
        #expect(try kept.route(Fixture.off(60), routing: strings).isEmpty)
        // A full panic is a reset: the marker goes with the strings note, and the next Note Off is unowned.
        var panicked = marked
        #expect(panicked.panic(allNotesAndSoundOff: false) == [Fixture.sentOff(Fixture.strings, 60)])
        Fixture.expectRefused(Fixture.off(60), unowned, in: panicked, routing: strings)
        // So is the loss of its input.
        var lost = marked
        #expect(lost.inputLost(Fixture.keys) == [Fixture.sentOff(Fixture.strings, 60)])
        Fixture.expectRefused(Fixture.off(60), unowned, in: lost, routing: strings)
    }

    @Test(arguments: [UInt8(120), 123, 124, 125, 126, 127])
    func allNotesOffClearsOwnReleaseMarkers(controller: UInt8) throws {
        var ledger = try Self.markedBeforeStrings()
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        let mode = { (channel: UInt8) in
            controller < 124 ? [] : [Fixture.sentControl(Fixture.strings, controller, 0, channel: channel)]
        }
        // On another channel it releases nothing of key 60 and keeps the marker.
        #expect(try ledger.route(Fixture.control(controller, 0, channel: 2), routing: strings) == mode(2))
        var kept = ledger
        #expect(try kept.route(Fixture.off(60), routing: strings).isEmpty)
        // On key 60's channel it releases strings and drops the marker: no Note Off of that key is pending.
        #expect(try ledger.route(Fixture.control(controller, 0), routing: strings)
            == [Fixture.sentOff(Fixture.strings, 60)] + mode(1))
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: strings)
    }

    @Test
    func releaseMarkersKeepPressOrder() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        let bass = try Fixture.routing(Fixture.rule(Fixture.bass))
        let pressure = Fixture.event(.polyphonicPressure(channel: 1, note: 60, pressure: 9))
        // Key 60 on piano, strings, then bass; bass is lost first, then piano: the markers keep press order.
        _ = try Fixture.play([Fixture.on(60)], on: &ledger, routing: piano)
        _ = try Fixture.play([Fixture.on(60)], on: &ledger, routing: strings)
        _ = try Fixture.play([Fixture.on(60)], on: &ledger, routing: bass)
        _ = ledger.routeLost(Fixture.bass)
        _ = ledger.routeLost(Fixture.piano)
        // Poly pressure follows the newest press still sounding; a marker has no destination.
        #expect(try ledger.route(pressure, routing: bass) == [Fixture.sentPressure(Fixture.strings, 60, 9)])
        // A later press queues behind the markers (piano was added again): its release comes last.
        #expect(try ledger.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
        #expect(try ledger.route(pressure, routing: bass) == [Fixture.sentPressure(Fixture.piano, 60, 9)])
        #expect(try ledger.route(Fixture.off(60), routing: piano).isEmpty)
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.strings, 60)])
        #expect(try ledger.route(Fixture.on(60, 0), routing: piano).isEmpty)
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: piano)

        // A press keeping a layer elsewhere is not marked: its Note Off ends that layer, the next one the next press.
        var partial = MIDINoteLedger()
        let layered = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings))
        _ = try Fixture.play([Fixture.on(62)], on: &partial, routing: layered)
        _ = try Fixture.play([Fixture.on(62)], on: &partial, routing: bass)
        _ = partial.routeLost(Fixture.piano)
        #expect(try partial.route(Fixture.off(62), routing: .empty) == [Fixture.sentOff(Fixture.strings, 62)])
        #expect(try partial.route(Fixture.off(62), routing: .empty) == [Fixture.sentOff(Fixture.bass, 62)])
    }

    @Test
    func releaseMarkersUnderPedals() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        // Under sustain: key 62 played and released on piano (its Note Off spent), key 60 still down there; both keys
        // again on strings (the pedal carried first). Piano is lost.
        _ = try Fixture.play([Fixture.control(64, 127), Fixture.on(62), Fixture.off(62), Fixture.on(60)], on: &ledger,
                             routing: piano)
        #expect(try Fixture.play([Fixture.on(62), Fixture.on(60)], on: &ledger, routing: strings) == [
            Fixture.sentControl(Fixture.strings, 64, 127), Fixture.sentOn(Fixture.strings, 62),
            Fixture.sentOn(Fixture.strings, 60)
        ])
        _ = ledger.routeLost(Fixture.piano)
        // Key 62's sustained press had no Note Off pending, so the next one is the strings press's.
        #expect(try ledger.route(Fixture.off(62), routing: strings) == [Fixture.sentOff(Fixture.strings, 62)])
        // Key 60's lost press was still down: its Note Off sends nothing and the strings note stays down.
        #expect(try ledger.route(Fixture.off(60), routing: strings).isEmpty)
        #expect(try ledger.route(Fixture.off(60), routing: strings) == [Fixture.sentOff(Fixture.strings, 60)])
        #expect(ledger.notes.map(\.sustained) == [true, true])
        #expect(try ledger.route(Fixture.control(64, 0), routing: strings)
            == [Fixture.sentControl(Fixture.strings, 64, 0)])
        #expect(ledger.notes.isEmpty)

        // Under sostenuto, a route-scoped panic takes the captured key-down press; its marker sends nothing either.
        var captured = MIDINoteLedger()
        _ = try Fixture.play([Fixture.on(64), Fixture.control(66, 127)], on: &captured, routing: piano)
        _ = try captured.route(Fixture.on(64), routing: strings)
        _ = captured.panic(.route(Fixture.piano))
        #expect(try captured.route(Fixture.off(64), routing: strings).isEmpty)
        #expect(try captured.route(Fixture.off(64), routing: strings) == [Fixture.sentOff(Fixture.strings, 64)])
        #expect(try captured.route(Fixture.control(66, 0), routing: strings)
            == [Fixture.sentControl(Fixture.strings, 66, 0)])
        #expect(captured.notes.isEmpty)
        #expect(captured.pedalHolds.isEmpty)
    }

    @Test
    func releaseMarkersAreNotDestinationOwnership() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        let shared = try Fixture.routing(
            Fixture.rule(Fixture.strings), Fixture.rule(Fixture.strings, from: Fixture.pads)
        )
        // Keys 60 on piano, pads 62 on strings, keys 60 on strings, pads 62 on piano; piano is lost.
        _ = try ledger.route(Fixture.on(60), routing: piano)
        _ = try ledger.route(Fixture.on(62, from: Fixture.pads), routing: shared)
        _ = try ledger.route(Fixture.on(60), routing: shared)
        _ = try ledger.route(Fixture.on(62, from: Fixture.pads), routing: piano)
        _ = ledger.routeLost(Fixture.piano)
        // Pads' key down on strings refuses keys' mode message whole; keys' marker survives the refusal.
        Fixture.expectRefused(Fixture.control(124, 0), .sharedDestinationOwned(
            input: Fixture.keys, channel: 1, controller: 124, route: Fixture.strings, owner: Fixture.pads
        ), in: ledger, routing: shared)
        // Pads' older strings press ends first; pads' newer marker is not ownership, so keys' mode message goes out
        // and drops only keys' marker.
        #expect(try ledger.route(Fixture.off(62, from: Fixture.pads), routing: shared)
            == [Fixture.sentOff(Fixture.strings, 62)])
        #expect(try ledger.route(Fixture.control(124, 0), routing: shared)
            == [Fixture.sentOff(Fixture.strings, 60), Fixture.sentControl(Fixture.strings, 124, 0)])
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: shared)
        #expect(try ledger.route(Fixture.off(62, from: Fixture.pads), routing: shared).isEmpty)
        Fixture.expectRefused(Fixture.off(62, from: Fixture.pads),
                              .unownedNote(input: Fixture.pads, channel: 1, note: 62), in: ledger, routing: shared)
    }
}
