import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct MIDIPerformanceSustainTests {
    typealias Fixture = MIDIPerformanceFixture

    @Test
    func sustainedNoteReleasesOnOriginalRoute() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        #expect(try ledger.route(Fixture.control(64, 127), routing: piano)
            == [Fixture.sentControl(Fixture.piano, 64, 127)])
        _ = try ledger.route(Fixture.on(60), routing: piano)
        #expect(try ledger.route(Fixture.off(60), routing: strings) == [Fixture.sentOff(Fixture.piano, 60)])
        let sustained = try #require(ledger.notes.first)
        #expect(sustained.keyDown == false)
        #expect(sustained.sustained)
        #expect(ledger.isPedalDown(.sustain, route: Fixture.piano, channel: 1))
        #expect(ledger.isPedalDown(.sustain, route: Fixture.strings, channel: 1) == false)
        // The held pedal reaches the new route before its first note.
        #expect(try ledger.route(Fixture.on(62), routing: strings)
            == [Fixture.sentControl(Fixture.strings, 64, 127), Fixture.sentOn(Fixture.strings, 62)])
        #expect(try ledger.route(Fixture.control(64, 0), routing: strings)
            == [Fixture.sentControl(Fixture.piano, 64, 0), Fixture.sentControl(Fixture.strings, 64, 0)])
        #expect(ledger.notes.map(\.route) == [Fixture.strings])
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func pedalDownReachesRoutesHoldingKeys() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        _ = try Fixture.play([Fixture.on(60), Fixture.on(61, channel: 2)], on: &ledger, routing: piano)
        #expect(try ledger.route(Fixture.control(64, 100), routing: strings)
            == [Fixture.sentControl(Fixture.strings, 64, 100), Fixture.sentControl(Fixture.piano, 64, 100)])
        #expect(try ledger.route(Fixture.off(60), routing: strings) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(ledger.notes.first?.sustained == true)
        // Channel 2 has no pedal, so its note ends at once.
        #expect(try ledger.route(Fixture.off(61, channel: 2), routing: strings)
            == [Fixture.sentOff(Fixture.piano, 61, channel: 2)])
        #expect(try ledger.route(Fixture.control(64, 0), routing: .empty)
            == [Fixture.sentControl(Fixture.piano, 64, 0), Fixture.sentControl(Fixture.strings, 64, 0)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func pedalUpWithoutHoldIsRefused() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let unownedSustain = MIDIPerformanceRefusal.unownedPedal(input: Fixture.keys, channel: 1, pedal: .sustain)
        Fixture.expectRefused(Fixture.control(64, 0), unownedSustain, in: ledger, routing: piano)
        Fixture.expectRefused(Fixture.control(66, 63),
                              .unownedPedal(input: Fixture.keys, channel: 1, pedal: .sostenuto), in: ledger,
                              routing: piano)
        #expect(try ledger.route(Fixture.control(64, 64), routing: piano)
            == [Fixture.sentControl(Fixture.piano, 64, 64)])
        #expect(ledger.pedalHolds == [
            MIDIPedalHold(route: Fixture.piano, channel: 1, pedal: .sustain, input: Fixture.keys)
        ])
        #expect(try ledger.route(Fixture.control(64, 63), routing: piano)
            == [Fixture.sentControl(Fixture.piano, 64, 0)])
        Fixture.expectRefused(Fixture.control(64, 0), unownedSustain, in: ledger, routing: piano)
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func sharedPedalReleasesWithLastHolder() throws {
        var ledger = MIDINoteLedger()
        let merged = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        #expect(try Fixture.play(
            [Fixture.control(64, 127), Fixture.control(64, 127, from: Fixture.pads)], on: &ledger, routing: merged
        ) == [Fixture.sentControl(Fixture.piano, 64, 127), Fixture.sentControl(Fixture.piano, 64, 127)])
        #expect(ledger.pedalHolds.map(\.input) == [Fixture.keys, Fixture.pads])
        _ = try Fixture.play([Fixture.on(60), Fixture.off(60)], on: &ledger, routing: merged)
        #expect(try ledger.route(Fixture.control(64, 0), routing: merged).isEmpty)
        #expect(ledger.notes.map(\.sustained) == [true])
        #expect(try ledger.route(Fixture.control(64, 0, from: Fixture.pads), routing: merged)
            == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func sostenutoCapturesOnlyKeysDown() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        _ = try ledger.route(Fixture.on(60), routing: piano)
        #expect(try ledger.route(Fixture.control(66, 127), routing: piano)
            == [Fixture.sentControl(Fixture.piano, 66, 127)])
        _ = try ledger.route(Fixture.on(62), routing: piano)
        // A second holder's pedal-down is not a new capture.
        _ = try ledger.route(Fixture.control(66, 127, from: Fixture.pads), routing: piano)
        #expect(ledger.notes.map(\.sostenuto) == [true, false])
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(try ledger.route(Fixture.off(62), routing: piano) == [Fixture.sentOff(Fixture.piano, 62)])
        #expect(ledger.notes.map(\.note) == [60])
        #expect(ledger.notes.first?.sustained == false)
        _ = try ledger.route(Fixture.control(66, 0, from: Fixture.pads), routing: piano)
        #expect(ledger.notes.map(\.note) == [60])
        #expect(try ledger.route(Fixture.control(66, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 66, 0)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func sustainAndSostenutoTogether() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let pressed = [Fixture.on(60), Fixture.control(66, 127), Fixture.control(64, 127), Fixture.off(60)]
        _ = try Fixture.play(pressed, on: &ledger, routing: piano)
        #expect(ledger.notes.map { [$0.keyDown, $0.sustained, $0.sostenuto] } == [[false, true, true]])
        _ = try ledger.route(Fixture.control(64, 0), routing: piano)
        #expect(ledger.notes.map { [$0.sustained, $0.sostenuto] } == [[false, true]])
        _ = try ledger.route(Fixture.control(66, 0), routing: piano)
        #expect(ledger.notes.isEmpty)

        _ = try Fixture.play(pressed, on: &ledger, routing: piano)
        _ = try ledger.route(Fixture.control(66, 0), routing: piano)
        #expect(ledger.notes.map { [$0.sustained, $0.sostenuto] } == [[true, false]])
        _ = try ledger.route(Fixture.control(64, 0), routing: piano)
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func sostenutoReleaseHandsKeyUpNoteToSustain() throws {
        let single = try #require(MIDINoteLedgerPolicy(noteCapacity: 1))
        var ledger = MIDINoteLedger(policy: single)
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try Fixture.play([Fixture.on(60), Fixture.control(66, 127), Fixture.off(60), Fixture.control(64, 127)],
                             on: &ledger, routing: piano)
        #expect(ledger.notes.map { [$0.keyDown, $0.sustained, $0.sostenuto] } == [[false, false, true]])
        // The sustain pedal is down when the sostenuto goes up, so the note keeps sounding and stays recorded.
        #expect(try ledger.route(Fixture.control(66, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 66, 0)])
        #expect(ledger.notes.map { [$0.keyDown, $0.sustained, $0.sostenuto] } == [[false, true, false]])
        Fixture.expectRefused(Fixture.on(62), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 62), in: ledger,
                              routing: piano)
        #expect(try ledger.route(Fixture.control(64, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(ledger.notes.isEmpty)
        #expect(try ledger.route(Fixture.on(62), routing: piano) == [Fixture.sentOn(Fixture.piano, 62)])
    }

    @Test
    func sustainReleaseLeavesSostenutoHeldNote() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try Fixture.play([
            Fixture.control(64, 127, channel: 2), Fixture.on(60), Fixture.control(66, 127), Fixture.off(60),
            Fixture.control(64, 127)
        ], on: &ledger, routing: piano)
        #expect(try ledger.route(Fixture.control(64, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(ledger.notes.map { [$0.keyDown, $0.sustained, $0.sostenuto] } == [[false, false, true]])
        // With this destination's sustain already up (channel 2's is not this destination), the sostenuto ends it.
        #expect(try ledger.route(Fixture.control(66, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 66, 0)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.pedalHolds.map(\.channel) == [2])
    }

    @Test
    func retriggerUnderSustain() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let played = [Fixture.control(64, 127), Fixture.on(60), Fixture.off(60), Fixture.on(60, 80), Fixture.off(60)]
        #expect(try Fixture.play(played, on: &ledger, routing: piano) == [
            Fixture.sentControl(Fixture.piano, 64, 127), Fixture.sentOn(Fixture.piano, 60),
            Fixture.sentOff(Fixture.piano, 60), Fixture.sentOn(Fixture.piano, 60, 80),
            Fixture.sentOff(Fixture.piano, 60)
        ])
        #expect(ledger.notes.map(\.sustained) == [true, true])
        #expect(try ledger.route(Fixture.control(64, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func allSoundOffReleasesOwnKeysThenPedals() throws {
        var ledger = MIDINoteLedger()
        let merged = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        let played = [
            Fixture.control(64, 127), Fixture.on(60), Fixture.control(66, 127), Fixture.on(62, from: Fixture.pads)
        ]
        _ = try Fixture.play(played, on: &ledger, routing: merged)
        #expect(try ledger.route(Fixture.control(120, 0), routing: merged) == [
            Fixture.sentOff(Fixture.piano, 60), Fixture.sentControl(Fixture.piano, 64, 0),
            Fixture.sentControl(Fixture.piano, 66, 0)
        ])
        #expect(ledger.notes.map(\.input) == [Fixture.pads])
        #expect(ledger.notes.first?.keyDown == true)
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func resetAllControllersReleasesOwnPedalsThenForwards() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        _ = try Fixture.play([Fixture.control(64, 127), Fixture.on(60), Fixture.off(60)], on: &ledger, routing: piano)
        #expect(try ledger.route(Fixture.control(121, 0), routing: strings)
            == [Fixture.sentControl(Fixture.piano, 64, 0), Fixture.sentControl(Fixture.strings, 121, 0)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func repeatedPedalDownValuesRecordOneHold() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let values: [UInt8] = [64, 100, 127]
        #expect(try Fixture.play(values.map { Fixture.control(64, $0) }, on: &ledger, routing: piano)
            == values.map { Fixture.sentControl(Fixture.piano, 64, $0) })
        #expect(ledger.pedalHolds.count == 1)
        // The first value below 64 releases the binary pedal fully.
        #expect(try ledger.route(Fixture.control(64, 30), routing: piano)
            == [Fixture.sentControl(Fixture.piano, 64, 0)])
        Fixture.expectRefused(Fixture.control(64, 0),
                              .unownedPedal(input: Fixture.keys, channel: 1, pedal: .sustain), in: ledger,
                              routing: piano)
    }

    @Test
    func halfPedalUpIsAFullReleaseOnEveryRoute() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        _ = try Fixture.play([Fixture.control(64, 127), Fixture.on(60), Fixture.off(60)], on: &ledger, routing: piano)
        _ = try Fixture.play([Fixture.on(62), Fixture.off(62)], on: &ledger, routing: strings)
        #expect(ledger.notes.map(\.sustained) == [true, true])
        // 127 → 30 → 0: each destination's last pedal value is 0, sent at the 30; the trailing 0 is benign.
        #expect(try ledger.route(Fixture.control(64, 30), routing: strings)
            == [Fixture.sentControl(Fixture.piano, 64, 0), Fixture.sentControl(Fixture.strings, 64, 0)])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.pedalHolds.isEmpty)
        Fixture.expectRefused(Fixture.control(64, 0),
                              .unownedPedal(input: Fixture.keys, channel: 1, pedal: .sustain), in: ledger,
                              routing: strings)
        #expect(ledger.panic().isEmpty)
    }

    @Test
    func pedalUpKeepsOtherRoutesSustained() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(
            Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings, from: Fixture.pads)
        )
        _ = try Fixture.play([
            Fixture.control(64, 127), Fixture.on(60), Fixture.off(60), Fixture.control(64, 127, from: Fixture.pads),
            Fixture.on(62, from: Fixture.pads), Fixture.off(62, from: Fixture.pads)
        ], on: &ledger, routing: routing)
        #expect(ledger.notes.map(\.sustained) == [true, true])
        #expect(try ledger.route(Fixture.control(64, 0), routing: routing)
            == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(ledger.notes.map(\.route) == [Fixture.strings])
        #expect(ledger.notes.first?.sustained == true)
        #expect(ledger.panic() == [
            Fixture.sentOff(Fixture.strings, 62), Fixture.sentControl(Fixture.strings, 64, 0),
            Fixture.sentControl(Fixture.strings, 123, 0), Fixture.sentControl(Fixture.strings, 120, 0)
        ])
    }

    @Test
    func pedalUpKeepsOtherChannelsSustained() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try Fixture.play([
            Fixture.control(64, 127), Fixture.on(60), Fixture.off(60),
            Fixture.control(64, 127, channel: 2), Fixture.on(61, channel: 2), Fixture.off(61, channel: 2)
        ], on: &ledger, routing: piano)
        #expect(try ledger.route(Fixture.control(64, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(ledger.notes.map(\.channel) == [2])
        #expect(ledger.notes.first?.sustained == true)
        #expect(ledger.panic() == [
            Fixture.sentOff(Fixture.piano, 61, channel: 2), Fixture.sentControl(Fixture.piano, 64, 0, channel: 2),
            Fixture.sentControl(Fixture.piano, 123, 0, channel: 2),
            Fixture.sentControl(Fixture.piano, 120, 0, channel: 2)
        ])
    }

    @Test
    func heldPedalsCarryToNewRoutesBeforeTheNote() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        // Strings twice (one carried pedal each), and a bass split that note 62 does not reach.
        let moved = try Fixture.routing(
            Fixture.rule(Fixture.strings), Fixture.rule(Fixture.strings, transpose: 12),
            Fixture.rule(Fixture.bass, notes: 0...59)
        )
        _ = try Fixture.play([Fixture.control(64, 127), Fixture.control(66, 127), Fixture.on(60)], on: &ledger,
                             routing: piano)
        #expect(try ledger.route(Fixture.on(62), routing: moved) == [
            Fixture.sentControl(Fixture.strings, 64, 127), Fixture.sentControl(Fixture.strings, 66, 127),
            Fixture.sentOn(Fixture.strings, 62), Fixture.sentOn(Fixture.strings, 74)
        ])
        // The note-on follows the carried sostenuto, so the sostenuto does not hold it.
        #expect(ledger.notes.map(\.sostenuto) == [false, false, false])
        #expect(ledger.pedalHolds.map(\.route) == [Fixture.piano, Fixture.piano, Fixture.strings, Fixture.strings])
        // Held already, on another channel, or not reached by the note: nothing is carried.
        #expect(try ledger.route(Fixture.on(64), routing: moved)
            == [Fixture.sentOn(Fixture.strings, 64), Fixture.sentOn(Fixture.strings, 76)])
        #expect(try ledger.route(Fixture.on(64, channel: 2), routing: moved)
            == [Fixture.sentOn(Fixture.strings, 64, channel: 2), Fixture.sentOn(Fixture.strings, 76, channel: 2)])
        _ = try Fixture.play([Fixture.off(60), Fixture.off(62), Fixture.off(64)], on: &ledger, routing: .empty)
        #expect(ledger.notes.map(\.sustained) == [true, true, true, true, true, false, false])
        #expect(try ledger.route(Fixture.control(64, 0), routing: .empty)
            == [Fixture.sentControl(Fixture.piano, 64, 0), Fixture.sentControl(Fixture.strings, 64, 0)])
        #expect(ledger.notes.map(\.channel) == [2, 2])
        #expect(try ledger.route(Fixture.control(66, 0), routing: .empty)
            == [Fixture.sentControl(Fixture.piano, 66, 0), Fixture.sentControl(Fixture.strings, 66, 0)])
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func carriedPedalsCountTowardCapacity() throws {
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        let pressed = [Fixture.control(64, 127), Fixture.on(60)]
        let full = try #require(MIDINoteLedgerPolicy(pedalCapacity: 1))
        var refused = MIDINoteLedger(policy: full)
        _ = try Fixture.play(pressed, on: &refused, routing: piano)
        Fixture.expectRefused(Fixture.on(62), .pedalLedgerFull(input: Fixture.keys, channel: 1, pedal: .sustain),
                              in: refused, routing: strings)

        let fits = try #require(MIDINoteLedgerPolicy(pedalCapacity: 2))
        var accepted = MIDINoteLedger(policy: fits)
        _ = try Fixture.play(pressed, on: &accepted, routing: piano)
        #expect(try accepted.route(Fixture.on(62), routing: strings)
            == [Fixture.sentControl(Fixture.strings, 64, 127), Fixture.sentOn(Fixture.strings, 62)])
        #expect(accepted.pedalHolds.count == 2)

        // A carried pedal that fits is withdrawn with the note when the note does not fit.
        let noteFull = try #require(MIDINoteLedgerPolicy(noteCapacity: 1, pedalCapacity: 2))
        var withdrawn = MIDINoteLedger(policy: noteFull)
        _ = try Fixture.play(pressed, on: &withdrawn, routing: piano)
        Fixture.expectRefused(Fixture.on(62), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 62),
                              in: withdrawn, routing: strings)
    }

    @Test
    func sostenutoCapturesOnlyItsRouteAndChannel() throws {
        var ledger = MIDINoteLedger()
        let routing = try Fixture.routing(
            Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings, from: Fixture.pads)
        )
        _ = try Fixture.play([Fixture.on(60, channel: 2), Fixture.on(62, from: Fixture.pads)], on: &ledger,
                             routing: routing)
        #expect(try ledger.route(Fixture.control(66, 127), routing: routing)
            == [Fixture.sentControl(Fixture.piano, 66, 127)])
        #expect(ledger.notes.map(\.sostenuto) == [false, false])
        #expect(try ledger.route(Fixture.off(60, channel: 2), routing: routing)
            == [Fixture.sentOff(Fixture.piano, 60, channel: 2)])
        #expect(try ledger.route(Fixture.off(62, from: Fixture.pads), routing: routing)
            == [Fixture.sentOff(Fixture.strings, 62)])
        #expect(ledger.notes.isEmpty)
    }
}
