import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Copilot round 2 (PR #343): a key-down press that loses every layer to a route loss or a route-scoped panic leaves a
/// release marker at its place in its key's release FIFO, so the Note Off that belongs to it sends nothing instead of
/// ending a newer press of the same key. Round 2b: a marker exists only while a newer key-down press of its key does;
/// otherwise it would order nothing and would swallow the Note Off of the key's next press.
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
        // A lost press is one marker whatever its layer count: two instances become one entry, ahead of strings.
        _ = try ledger.route(Fixture.on(60), routing: octaves)
        _ = try ledger.route(Fixture.on(60), routing: strings)
        _ = ledger.routeLost(Fixture.piano)
        #expect(ledger.releaseMarkers.count == 1)
        // N: the marker and two notes fill the three entries. N + 1 is refused whole and changes nothing.
        #expect(try ledger.route(Fixture.on(62), routing: strings) == [Fixture.sentOn(Fixture.strings, 62)])
        Fixture.expectRefused(Fixture.on(64), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 64), in: ledger,
                              routing: strings)
        // The Note Off that consumes the marker frees its entry.
        #expect(try ledger.route(Fixture.off(60), routing: strings).isEmpty)
        #expect(try ledger.route(Fixture.on(64), routing: strings) == [Fixture.sentOn(Fixture.strings, 64)])
        Fixture.expectRefused(Fixture.on(65), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 65), in: ledger,
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
        let octave = try Fixture.routing(Fixture.rule(Fixture.strings, transpose: 12))
        let pressure = Fixture.event(.polyphonicPressure(channel: 1, note: 60, pressure: 9))
        // Key 60 on piano, strings, bass, then strings an octave up; bass is lost first, then piano: each marker keeps
        // its press's place between the presses still sounding.
        for routing in [piano, strings, bass, octave] {
            _ = try Fixture.play([Fixture.on(60)], on: &ledger, routing: routing)
        }
        _ = ledger.routeLost(Fixture.bass)
        _ = ledger.routeLost(Fixture.piano)
        #expect(ledger.releaseMarkers.map(\.press) == [0, 2])
        // Poly pressure follows the newest press still sounding; a marker has no destination.
        #expect(try ledger.route(pressure, routing: bass) == [Fixture.sentPressure(Fixture.strings, 72, 9)])
        // A later press (piano was added again) queues behind the markers and the presses they order: it ends last.
        #expect(try ledger.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
        #expect(try ledger.route(pressure, routing: bass) == [Fixture.sentPressure(Fixture.piano, 60, 9)])
        #expect(try ledger.route(Fixture.off(60), routing: piano).isEmpty)
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.strings, 60)])
        #expect(try ledger.route(Fixture.on(60, 0), routing: piano).isEmpty)
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.strings, 72)])
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
        // Keys 60 on piano, pads 62 on strings, keys 60 on strings, pads 62 on piano, then on bass; piano is lost.
        _ = try ledger.route(Fixture.on(60), routing: piano)
        _ = try ledger.route(Fixture.on(62, from: Fixture.pads), routing: shared)
        _ = try ledger.route(Fixture.on(60), routing: shared)
        _ = try ledger.route(Fixture.on(62, from: Fixture.pads), routing: piano)
        _ = try ledger.route(Fixture.on(62, from: Fixture.pads), routing: Fixture.routing(
            Fixture.rule(Fixture.bass, from: Fixture.pads)
        ))
        _ = ledger.routeLost(Fixture.piano)
        #expect(ledger.releaseMarkers.map(\.input) == [Fixture.keys, Fixture.pads])
        // Pads' key down on strings refuses keys' mode message whole; keys' marker survives the refusal.
        Fixture.expectRefused(Fixture.control(124, 0), .sharedDestinationOwned(
            input: Fixture.keys, channel: 1, controller: 124, route: Fixture.strings, owner: Fixture.pads
        ), in: ledger, routing: shared)
        // Pads' older strings press ends first; pads' marker (ahead of its bass press) is not ownership, so keys' mode
        // message goes out and drops only keys' marker.
        #expect(try ledger.route(Fixture.off(62, from: Fixture.pads), routing: shared)
            == [Fixture.sentOff(Fixture.strings, 62)])
        #expect(try ledger.route(Fixture.control(124, 0), routing: shared)
            == [Fixture.sentOff(Fixture.strings, 60), Fixture.sentControl(Fixture.strings, 124, 0)])
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: shared)
        #expect(try ledger.route(Fixture.off(62, from: Fixture.pads), routing: shared).isEmpty)
        #expect(try ledger.route(Fixture.off(62, from: Fixture.pads), routing: shared)
            == [Fixture.sentOff(Fixture.bass, 62)])
        Fixture.expectRefused(Fixture.off(62, from: Fixture.pads),
                              .unownedNote(input: Fixture.pads, channel: 1, note: 62), in: ledger, routing: shared)
    }

    // MARK: - Round 2b: a marker lives only while a newer key-down press of its key does

    /// Delta review: a press whose Note Off was lost, then a route-scoped panic, left a marker that swallowed the next
    /// press's Note Off (piano stuck), and the next panic left it again.
    @Test
    func routeScopedPanicLeavesNoMarkerWithoutNewerPress() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        for _ in 0..<2 {
            _ = try ledger.route(Fixture.on(60), routing: piano)
            #expect(ledger.panic(.route(Fixture.piano)) == [
                Fixture.sentOff(Fixture.piano, 60), Fixture.sentControl(Fixture.piano, 123, 0),
                Fixture.sentControl(Fixture.piano, 120, 0)
            ])
            #expect(ledger.releaseMarkers.isEmpty)
            #expect(try ledger.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
            #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
            #expect(ledger.notes.isEmpty)
        }
        #expect(ledger.panic(.route(Fixture.piano)).isEmpty)
        #expect(ledger.releaseMarkers.isEmpty)
    }

    @Test
    func routeLossLeavesNoMarkerWithoutNewerPress() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try ledger.route(Fixture.on(60), routing: piano)
        #expect(ledger.routeLost(Fixture.piano).notes.map(\.note) == [60])
        #expect(ledger.releaseMarkers.isEmpty)
        // Piano reconnects: the next press of the key ends with its own Note Off.
        #expect(try ledger.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.releaseMarkers.isEmpty)
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: piano)
    }

    /// Copilot (PR #343, MIDINoteLedger.swift:453): a sole press to piano is lost and its Note Off never comes; the
    /// key's next press, on strings, must end with its own Note Off.
    @Test
    func soleLostPressLeavesNoMarkerForTheNextRoute() throws {
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        var lost = MIDINoteLedger()
        _ = try lost.route(Fixture.on(60), routing: Fixture.routing(Fixture.rule(Fixture.piano)))
        var panicked = lost
        _ = lost.routeLost(Fixture.piano)
        _ = panicked.panic(.route(Fixture.piano))
        for var ledger in [lost, panicked] {
            #expect(ledger.releaseMarkers.isEmpty)
            #expect(try ledger.route(Fixture.on(60), routing: strings) == [Fixture.sentOn(Fixture.strings, 60)])
            #expect(try ledger.route(Fixture.off(60), routing: strings) == [Fixture.sentOff(Fixture.strings, 60)])
            #expect(ledger.notes.isEmpty)
            #expect(ledger.releaseMarkers.isEmpty)
        }
    }

    /// A marker goes when the newer press it orders is lost too, by a route loss or a route-scoped panic.
    @Test
    func releaseMarkerPrunedWithItsNewerPress() throws {
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        var lost = try Self.markedBeforeStrings()
        #expect(lost.releaseMarkers.count == 1)
        #expect(lost.routeLost(Fixture.strings).notes.map(\.note) == [60])
        var panicked = try Self.markedBeforeStrings()
        #expect(panicked.panic(.route(Fixture.strings), allNotesAndSoundOff: false)
            == [Fixture.sentOff(Fixture.strings, 60)])
        for var ledger in [lost, panicked] {
            #expect(ledger.releaseMarkers.isEmpty)
            #expect(try ledger.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
            #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
            #expect(ledger.notes.isEmpty)
        }
    }

    /// Key 60 on piano (p1), strings (p2), then bass (p3).
    @Test
    func releaseMarkersBetweenThreePresses() throws {
        var ledger = MIDINoteLedger()
        let unowned = MIDIPerformanceRefusal.unownedNote(input: Fixture.keys, channel: 1, note: 60)
        for route in [Fixture.piano, Fixture.strings, Fixture.bass] {
            _ = try ledger.route(Fixture.on(60), routing: Fixture.routing(Fixture.rule(route)))
        }
        // Strings is lost: p1, m2, p3.
        var middle = ledger
        _ = middle.routeLost(Fixture.strings)
        #expect(middle.releaseMarkers.map(\.press) == [1])
        var ordered = middle
        #expect(try ordered.route(Fixture.off(60), routing: .empty) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(try ordered.route(Fixture.off(60), routing: .empty).isEmpty)
        #expect(try ordered.route(Fixture.off(60), routing: .empty) == [Fixture.sentOff(Fixture.bass, 60)])
        Fixture.expectRefused(Fixture.off(60), unowned, in: ordered, routing: .empty)
        // Then p3 is lost: m2 orders nothing (p1 is older) and goes.
        _ = middle.routeLost(Fixture.bass)
        #expect(middle.releaseMarkers.isEmpty)
        #expect(try middle.route(Fixture.off(60), routing: .empty) == [Fixture.sentOff(Fixture.piano, 60)])
        Fixture.expectRefused(Fixture.off(60), unowned, in: middle, routing: .empty)
        // Piano is lost, then bass: m1 stays, as p2 is still down after it.
        var first = ledger
        _ = first.routeLost(Fixture.piano)
        _ = first.panic(.route(Fixture.bass))
        #expect(first.releaseMarkers.map(\.press) == [0])
        #expect(try first.route(Fixture.off(60), routing: .empty).isEmpty)
        #expect(try first.route(Fixture.off(60), routing: .empty) == [Fixture.sentOff(Fixture.strings, 60)])
        Fixture.expectRefused(Fixture.off(60), unowned, in: first, routing: .empty)
    }

    /// Only a newer key-down press of the same input, channel and note that outlives the loss keeps a marker: not
    /// one of another input or note, nor one lost with it.
    @Test
    func releaseMarkerNeedsSurvivingNewerPressOfItsKey() throws {
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(
            Fixture.rule(Fixture.strings), Fixture.rule(Fixture.strings, from: Fixture.pads)
        )
        let newer = [
            [(Fixture.on(60, from: Fixture.pads), strings)], [(Fixture.on(62), strings)], [(Fixture.on(60), piano)]
        ]
        for presses in newer {
            var ledger = MIDINoteLedger()
            _ = try ledger.route(Fixture.on(60), routing: piano)
            for (event, routing) in presses { _ = try ledger.route(event, routing: routing) }
            var panicked = ledger
            _ = ledger.routeLost(Fixture.piano)
            _ = panicked.panic(.route(Fixture.piano))
            for var cleared in [ledger, panicked] {
                #expect(cleared.releaseMarkers.isEmpty)
                Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60),
                                      in: cleared, routing: piano)
                #expect(try cleared.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
                #expect(try cleared.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
            }
        }
    }

    /// Markers of one note on two inputs and two channels are independent, and so is their pruning.
    @Test
    func releaseMarkersPerInputAndChannel() throws {
        var ledger = MIDINoteLedger()
        // Pads' layer sounds an octave up, so its note-off is not held back by keys' copy on the same route.
        let all = { (route: MIDIRouteID) in
            try Fixture.routing(Fixture.rule(route), Fixture.rule(route, from: Fixture.pads, transpose: 12))
        }
        let lanes = [Fixture.on(60), Fixture.on(60, channel: 2), Fixture.on(60, from: Fixture.pads)]
        _ = try Fixture.play(lanes, on: &ledger, routing: all(Fixture.piano))
        _ = try Fixture.play([lanes[0], lanes[2]], on: &ledger, routing: all(Fixture.strings))
        _ = try Fixture.play([lanes[1]], on: &ledger, routing: all(Fixture.bass))
        _ = ledger.routeLost(Fixture.piano)
        #expect(ledger.releaseMarkers.map(\.press) == [0, 1, 2])
        // Losing bass ends only keys' channel 2 press, so only its marker goes.
        _ = ledger.routeLost(Fixture.bass)
        #expect(ledger.releaseMarkers.map(\.channel) == [1, 1])
        #expect(ledger.releaseMarkers.map(\.input) == [Fixture.keys, Fixture.pads])
        Fixture.expectRefused(Fixture.off(60, channel: 2), .unownedNote(input: Fixture.keys, channel: 2, note: 60),
                              in: ledger, routing: .empty)
        #expect(try ledger.route(Fixture.off(60, from: Fixture.pads), routing: .empty).isEmpty)
        #expect(try ledger.route(Fixture.off(60), routing: .empty).isEmpty)
        #expect(try ledger.route(Fixture.off(60, from: Fixture.pads), routing: .empty)
            == [Fixture.sentOff(Fixture.strings, 72)])
        #expect(try ledger.route(Fixture.off(60), routing: .empty) == [Fixture.sentOff(Fixture.strings, 60)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.releaseMarkers.isEmpty)
    }

    /// Documented limit (DESIGN policy 17): a key-down press that reached no route records nothing, so its Note Off
    /// ends the key's next routed press early. It cannot be told apart from a Note Off that never comes.
    @Test
    func documentedLimitUnroutedPressDoesNotHoldItsPlace() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        #expect(try ledger.route(Fixture.on(60), routing: .empty).isEmpty)
        #expect(try ledger.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: piano)
    }

    // MARK: - Round 2c: seeded random sequences

    /// Delta review: notes, releases, pedals, channel mode messages, route losses (the route is reused at once, as
    /// if reconnected), panics and input losses at random over two inputs, two channels, two keys and three routes,
    /// with small capacities so refusals happen. A refusal changes nothing. After every step each marker orders a
    /// newer key-down press of its key, markers are sorted by press, and notes and markers fit the note capacity.
    @Test(arguments: [UInt64(1), 4, 8, 343])
    func randomSequencesKeepReleaseMarkerInvariants(seed: UInt64) throws {
        let policy = try #require(MIDINoteLedgerPolicy(noteCapacity: 12, pedalCapacity: 6))
        let routes = [Fixture.piano, Fixture.strings, Fixture.bass]
        let inputs = [Fixture.keys, Fixture.pads]
        // Every subset of the routes for both inputs (the empty one leaves a press unrouted), an octave layer, a split.
        var routings = try (0..<8).map { mask in
            try #require(MIDIRouting(rules: routes.indices.filter { mask >> $0 & 1 == 1 }.flatMap { index in
                try inputs.map { try Fixture.rule(routes[index], from: $0) }
            }))
        }
        routings.append(try Fixture.routing(
            Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, transpose: 12),
            Fixture.rule(Fixture.bass, from: Fixture.pads, channels: 1...1)
        ))
        var random = ReleaseMarkerSplitMix64(state: seed)
        var ledger = MIDINoteLedger(policy: policy)
        var markersSeen = 0
        for step in 0..<400 {
            let route = routes[random.next(3)]
            switch random.next(100) {
            case ..<70:
                let event = Self.randomEvent(input: inputs[random.next(2)], using: &random)
                let before = ledger
                var outputs: [MIDIRoutedOutput] = []
                do {
                    try ledger.route(event, routing: routings[random.next(routings.count)], into: &outputs)
                } catch {
                    #expect(outputs.isEmpty && ledger == before, "seed \(seed) step \(step): \(error)")
                }
            case ..<82: _ = ledger.routeLost(route)
            case ..<94: _ = ledger.panic(.route(route), allNotesAndSoundOff: random.next(2) == 0)
            case ..<96: _ = ledger.panic()
            default: _ = ledger.inputLost(inputs[random.next(2)])
            }
            let markers = ledger.releaseMarkers
            markersSeen += markers.count
            try #require(markers.allSatisfy { marker in
                ledger.notes.contains {
                    $0.keyDown && $0.press > marker.press && $0.input == marker.input
                        && $0.channel == marker.channel && $0.inputNote == marker.inputNote
                }
            }, "seed \(seed) step \(step): a marker orders no newer key-down press")
            try #require(zip(markers, markers.dropFirst()).allSatisfy { $0.press < $1.press },
                         "seed \(seed) step \(step): markers out of press order")
            try #require(ledger.notes.count + markers.count <= policy.noteCapacity,
                         "seed \(seed) step \(step): over the note capacity")
        }
        #expect(markersSeen > 0)
    }

    /// A Note On (velocity 1...127), Note Off, Note On velocity 0, sustain, sostenuto or soft pedal change, or
    /// CC 120, 121 or 123...127, on channel 1 or 2 and key 60 or 62.
    private static func randomEvent(
        input: MIDIInputID, using random: inout ReleaseMarkerSplitMix64
    ) -> MIDIPerformanceEvent {
        let channel = UInt8(1 + random.next(2))
        let note = UInt8(60 + 2 * random.next(2))
        let pedal = UInt8([64, 66, 67][random.next(3)])
        let mode = UInt8([120, 121, 123, 124, 125, 126, 127][random.next(7)])
        let message: MIDI1Semantic = switch random.next(12) {
        case 0...5: .noteOn(channel: channel, note: note, velocity: UInt8(1 + random.next(127)))
        case 6...7: .noteOff(channel: channel, note: note, velocity: UInt8(random.next(128)))
        case 8: .noteOn(channel: channel, note: note, velocity: 0)
        case 9...10: .controlChange(channel: channel, controller: pedal, value: UInt8(random.next(128)))
        default: .controlChange(channel: channel, controller: mode, value: 0)
        }
        return Fixture.event(message, from: input)
    }
}

/// SplitMix64, so each seed replays the same sequence everywhere.
private struct ReleaseMarkerSplitMix64 {
    var state: UInt64

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((mixed ^ (mixed >> 31)) % UInt64(bound))
    }
}
