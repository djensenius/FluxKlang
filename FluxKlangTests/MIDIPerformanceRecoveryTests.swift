import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct MIDIPerformanceRecoveryTests {
    typealias Fixture = MIDIPerformanceFixture

    /// Piano: key 48 down and key 60 sustained on channel 1. Strings: key 62 held by sostenuto on channel 2 and key 72
    /// down on channel 3.
    static func sounding() throws -> MIDINoteLedger {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings))
        _ = try Fixture.play(
            [Fixture.control(64, 127), Fixture.on(60), Fixture.off(60)], on: &ledger, routing: piano
        )
        _ = try Fixture.play(
            [Fixture.on(62, channel: 2), Fixture.control(66, 127, channel: 2), Fixture.off(62, channel: 2)],
            on: &ledger, routing: strings
        )
        _ = try ledger.route(Fixture.on(48), routing: piano)
        _ = try ledger.route(Fixture.on(72, channel: 3), routing: strings)
        return ledger
    }

    @Test
    func panicOrder() throws {
        var ledger = try Self.sounding()
        #expect(ledger.notes.map(\.note) == [60, 62, 48, 72])
        #expect(ledger.panic() == [
            Fixture.sentOff(Fixture.piano, 48), Fixture.sentOff(Fixture.piano, 60),
            Fixture.sentControl(Fixture.piano, 64, 0),
            Fixture.sentControl(Fixture.piano, 123, 0), Fixture.sentControl(Fixture.piano, 120, 0),
            Fixture.sentOff(Fixture.strings, 62, channel: 2), Fixture.sentOff(Fixture.strings, 72, channel: 3),
            Fixture.sentControl(Fixture.strings, 66, 0, channel: 2),
            Fixture.sentControl(Fixture.strings, 123, 0, channel: 2),
            Fixture.sentControl(Fixture.strings, 120, 0, channel: 2),
            Fixture.sentControl(Fixture.strings, 123, 0, channel: 3),
            Fixture.sentControl(Fixture.strings, 120, 0, channel: 3)
        ])
        #expect(ledger.notes.isEmpty)
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func panicIsIdempotent() throws {
        var ledger = try Self.sounding()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        #expect(ledger.panic().count == 12)
        #expect(ledger.panic().isEmpty)
        #expect(ledger.notes.isEmpty)
        #expect(ledger.pedalHolds.isEmpty)
        // Releases after a panic have nothing left to release: each is refused and nothing stray is sent.
        Fixture.expectRefused(Fixture.off(48), .unownedNote(input: Fixture.keys, channel: 1, note: 48), in: ledger,
                              routing: piano)
        Fixture.expectRefused(Fixture.control(64, 0),
                              .unownedPedal(input: Fixture.keys, channel: 1, pedal: .sustain), in: ledger,
                              routing: piano)
        Fixture.expectRefused(Fixture.control(66, 0, channel: 2),
                              .unownedPedal(input: Fixture.keys, channel: 2, pedal: .sostenuto), in: ledger,
                              routing: piano)
        _ = try ledger.route(Fixture.on(50), routing: piano)
        #expect(ledger.panic() == [
            Fixture.sentOff(Fixture.piano, 50), Fixture.sentControl(Fixture.piano, 123, 0),
            Fixture.sentControl(Fixture.piano, 120, 0)
        ])
        #expect(ledger.panic(allNotesAndSoundOff: false).isEmpty)
    }

    @Test
    func panicSilencesPedalOnlyChannels() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try ledger.route(Fixture.control(66, 127, channel: 5), routing: piano)
        #expect(ledger.panic() == [
            Fixture.sentControl(Fixture.piano, 66, 0, channel: 5),
            Fixture.sentControl(Fixture.piano, 123, 0, channel: 5),
            Fixture.sentControl(Fixture.piano, 120, 0, channel: 5)
        ])
        #expect(ledger.panic().isEmpty)
    }

    @Test
    func unownedReleasesOnEmptyLedgerAreRefused() throws {
        let ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let unowned = MIDIPerformanceRefusal.unownedNote(input: Fixture.keys, channel: 1, note: 60)
        Fixture.expectRefused(Fixture.off(60), unowned, in: ledger, routing: piano)
        Fixture.expectRefused(Fixture.on(60, 0), unowned, in: ledger, routing: piano)
        Fixture.expectRefused(Fixture.event(.polyphonicPressure(channel: 1, note: 60, pressure: 9)), unowned,
                              in: ledger, routing: piano)
        Fixture.expectRefused(Fixture.control(64, 0),
                              .unownedPedal(input: Fixture.keys, channel: 1, pedal: .sustain), in: ledger,
                              routing: piano)
        Fixture.expectRefused(Fixture.control(66, 0),
                              .unownedPedal(input: Fixture.keys, channel: 1, pedal: .sostenuto), in: ledger,
                              routing: piano)
        // Bulk releases have nothing to release and are not refused.
        var empty = ledger
        #expect(try Fixture.play([Fixture.control(120, 0), Fixture.control(123, 0)], on: &empty, routing: piano)
            .isEmpty)
    }

    @Test
    func releasesOwnedElsewhereAreRefused() throws {
        var ledger = MIDINoteLedger()
        let merged = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings, from: Fixture.pads))
        _ = try Fixture.play([Fixture.on(60), Fixture.control(64, 127, from: Fixture.pads)], on: &ledger,
                             routing: merged)
        // Another input's key or pedal, or this input's key on another channel, is not this event's to release.
        Fixture.expectRefused(Fixture.off(60, from: Fixture.pads),
                              .unownedNote(input: Fixture.pads, channel: 1, note: 60), in: ledger, routing: merged)
        Fixture.expectRefused(Fixture.off(60, channel: 2), .unownedNote(input: Fixture.keys, channel: 2, note: 60),
                              in: ledger, routing: merged)
        Fixture.expectRefused(Fixture.control(64, 0),
                              .unownedPedal(input: Fixture.keys, channel: 1, pedal: .sustain), in: ledger,
                              routing: merged)
        // A route or input lost since the note-on leaves its release unowned.
        var lost = ledger
        _ = lost.routeLost(Fixture.piano)
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: lost,
                              routing: merged)
        _ = lost.inputLost(Fixture.pads)
        Fixture.expectRefused(Fixture.control(64, 0, from: Fixture.pads),
                              .unownedPedal(input: Fixture.pads, channel: 1, pedal: .sustain), in: lost,
                              routing: merged)
    }

    @Test
    func heldBackReleasesAreNotRefused() throws {
        var ledger = MIDINoteLedger()
        let merged = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        _ = try Fixture.play([
            Fixture.on(60), Fixture.on(60), Fixture.control(64, 127), Fixture.control(64, 127, from: Fixture.pads)
        ], on: &ledger, routing: merged)
        // Another copy of the note, or another holder of the pedal, keeps it down: nothing to send, no refusal.
        #expect(try ledger.route(Fixture.off(60), routing: merged).isEmpty)
        #expect(try ledger.route(Fixture.control(64, 0), routing: merged).isEmpty)
        #expect(ledger.notes.map(\.keyDown) == [false, true])
        #expect(ledger.pedalHolds.map(\.input) == [Fixture.pads])
        #expect(try ledger.route(Fixture.off(60), routing: merged) == [Fixture.sentOff(Fixture.piano, 60)])
    }

    @Test
    func resetAllControllersRefusedWhereAnotherInputOwns() throws {
        var ledger = MIDINoteLedger()
        let shared = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        // Pads sustain a released note where keys also play; keys hold their own sustain there too.
        _ = try Fixture.play([
            Fixture.control(64, 127, from: Fixture.pads), Fixture.on(62, from: Fixture.pads),
            Fixture.off(62, from: Fixture.pads), Fixture.control(64, 127)
        ], on: &ledger, routing: shared)
        Fixture.expectRefused(Fixture.control(121, 0), .sharedDestinationOwned(
            input: Fixture.keys, channel: 1, controller: 121, route: Fixture.piano, owner: Fixture.pads
        ), in: ledger, routing: shared)
        // Keys alone on strings channel 1 (pads own only channel 2 there): forwarded; the piano hold is pads' too.
        let exclusive = try Fixture.routing(
            Fixture.rule(Fixture.strings), Fixture.rule(Fixture.strings, from: Fixture.pads, channels: 2...2)
        )
        _ = try ledger.route(Fixture.on(64, channel: 2, from: Fixture.pads), routing: exclusive)
        #expect(try ledger.route(Fixture.control(121, 0), routing: exclusive)
            == [Fixture.sentControl(Fixture.strings, 121, 0)])
        #expect(ledger.pedalHolds.map(\.input) == [Fixture.pads])
        #expect(ledger.notes.map(\.note) == [62, 64])
    }

    @Test
    func resetForwardsOnceOtherOwnershipEnds() throws {
        var ledger = MIDINoteLedger()
        let shared = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        let refused = MIDIPerformanceRefusal.sharedDestinationOwned(
            input: Fixture.keys, channel: 1, controller: 121, route: Fixture.piano, owner: Fixture.pads
        )
        // A pedal hold alone is ownership; so is a key down. Each ends with its release, and the reset then forwards.
        _ = try ledger.route(Fixture.control(64, 127, from: Fixture.pads), routing: shared)
        Fixture.expectRefused(Fixture.control(121, 0), refused, in: ledger, routing: shared)
        _ = try ledger.route(Fixture.control(64, 0, from: Fixture.pads), routing: shared)
        #expect(try ledger.route(Fixture.control(121, 0), routing: shared)
            == [Fixture.sentControl(Fixture.piano, 121, 0)])
        _ = try ledger.route(Fixture.on(62, from: Fixture.pads), routing: shared)
        Fixture.expectRefused(Fixture.control(121, 0), refused, in: ledger, routing: shared)
        _ = try ledger.route(Fixture.off(62, from: Fixture.pads), routing: shared)
        #expect(try ledger.route(Fixture.control(121, 0), routing: shared)
            == [Fixture.sentControl(Fixture.piano, 121, 0)])
    }

    @Test
    func panicWithoutModeMessagesSendsOneOffPerOutputNote() throws {
        var ledger = MIDINoteLedger()
        let octaves = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, transpose: 12))
        _ = try Fixture.play(
            [Fixture.on(60), Fixture.on(60), Fixture.on(48), Fixture.control(64, 127)], on: &ledger, routing: octaves
        )
        #expect(ledger.notes.count == 6)
        #expect(ledger.panic(allNotesAndSoundOff: false) == [
            Fixture.sentOff(Fixture.piano, 48), Fixture.sentOff(Fixture.piano, 60), Fixture.sentOff(Fixture.piano, 72),
            Fixture.sentControl(Fixture.piano, 64, 0)
        ])
        #expect(ledger.panic().isEmpty)
    }

    @Test
    func routeScopedPanic() throws {
        var ledger = try Self.sounding()
        #expect(ledger.panic(.route(Fixture.strings), allNotesAndSoundOff: false) == [
            Fixture.sentOff(Fixture.strings, 62, channel: 2), Fixture.sentOff(Fixture.strings, 72, channel: 3),
            Fixture.sentControl(Fixture.strings, 66, 0, channel: 2)
        ])
        #expect(ledger.notes.map(\.route) == [Fixture.piano, Fixture.piano])
        #expect(ledger.panic(.route(Fixture.strings)).isEmpty)
        #expect(ledger.panic(.route(Fixture.bass)).isEmpty)
        #expect(ledger.panic(allNotesAndSoundOff: false) == [
            Fixture.sentOff(Fixture.piano, 48), Fixture.sentOff(Fixture.piano, 60),
            Fixture.sentControl(Fixture.piano, 64, 0)
        ])
        #expect(ledger.pedalHolds.isEmpty)
    }

    @Test
    func panicWorstCaseIsBounded() throws {
        let policy = try #require(MIDINoteLedgerPolicy(noteCapacity: 2048, pedalCapacity: 32))
        var ledger = MIDINoteLedger(policy: policy)
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        var outputs: [MIDIRoutedOutput] = []
        outputs.reserveCapacity(ledger.maximumOutputsPerEvent)
        for channel in UInt8(1)...16 {
            for note in UInt8(0)...127 {
                outputs.removeAll(keepingCapacity: true)
                try ledger.route(Fixture.on(note, channel: channel), routing: piano, into: &outputs)
            }
            try ledger.route(Fixture.control(64, 127, channel: channel), routing: piano, into: &outputs)
            try ledger.route(Fixture.control(66, 127, channel: channel), routing: piano, into: &outputs)
        }
        #expect(ledger.notes.count == 2048)
        #expect(ledger.pedalHolds.count == 32)
        Fixture.expectRefused(Fixture.on(0), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 0), in: ledger,
                              routing: piano)
        let silenced = ledger.panic()
        #expect(silenced.count == MIDINoteLedger.maximumPanicOutputsPerRoute)
        #expect(silenced.count <= ledger.maximumPanicOutputs)
        #expect(silenced.allSatisfy { $0.route == Fixture.piano })
        #expect(silenced.first == Fixture.sentOff(Fixture.piano, 0))
        #expect(silenced.last == Fixture.sentControl(Fixture.piano, 120, 0, channel: 16))
        #expect(ledger.panic().isEmpty)
    }

    @Test
    func routeLossOrphans() throws {
        var ledger = MIDINoteLedger()
        let layered = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings))
        _ = try Fixture.play(
            [Fixture.control(64, 127), Fixture.on(60), Fixture.off(60), Fixture.on(62)], on: &ledger, routing: layered
        )
        let orphaned = ledger.routeLost(Fixture.strings)
        #expect(orphaned.route == Fixture.strings)
        #expect(orphaned.notes.map(\.note) == [60, 62])
        #expect(orphaned.notes.allSatisfy { $0.route == Fixture.strings })
        #expect(orphaned.notes.map(\.keyDown) == [false, true])
        #expect(orphaned.pedalHolds == [
            MIDIPedalHold(route: Fixture.strings, channel: 1, pedal: .sustain, input: Fixture.keys)
        ])
        #expect(ledger.notes.allSatisfy { $0.route == Fixture.piano })
        #expect(ledger.pedalHolds.map(\.route) == [Fixture.piano])

        // Releases and panics no longer target the lost route, even with it still in the routing table.
        #expect(try ledger.route(Fixture.off(62), routing: layered) == [Fixture.sentOff(Fixture.piano, 62)])
        #expect(ledger.panic() == [
            Fixture.sentOff(Fixture.piano, 60), Fixture.sentOff(Fixture.piano, 62),
            Fixture.sentControl(Fixture.piano, 64, 0),
            Fixture.sentControl(Fixture.piano, 123, 0), Fixture.sentControl(Fixture.piano, 120, 0)
        ])
        let again = ledger.routeLost(Fixture.strings)
        #expect(again.notes.isEmpty)
        #expect(again.pedalHolds.isEmpty)
    }

    @Test
    func inputLossReleasesOwnedNotesAndPedals() throws {
        var ledger = MIDINoteLedger()
        let first = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings, from: Fixture.pads))
        let moved = try Fixture.routing(Fixture.rule(Fixture.bass, transpose: 2))
        _ = try Fixture.play([
            Fixture.control(64, 127, from: Fixture.pads), Fixture.on(60), Fixture.control(64, 127), Fixture.off(60),
            Fixture.on(64), Fixture.on(60, from: Fixture.pads)
        ], on: &ledger, routing: first)
        #expect(try ledger.route(Fixture.on(67), routing: moved)
            == [Fixture.sentControl(Fixture.bass, 64, 127), Fixture.sentOn(Fixture.bass, 69)])
        #expect(ledger.inputLost(Fixture.keys) == [
            Fixture.sentOff(Fixture.piano, 64), Fixture.sentOff(Fixture.bass, 69),
            Fixture.sentControl(Fixture.piano, 64, 0), Fixture.sentControl(Fixture.bass, 64, 0)
        ])
        #expect(ledger.notes.map(\.input) == [Fixture.pads])
        #expect(ledger.pedalHolds.map(\.input) == [Fixture.pads])
        #expect(ledger.inputLost(Fixture.keys).isEmpty)

        // A note another input's pedal sustains stays until that pedal is released.
        var shared = MIDINoteLedger()
        let merged = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        _ = try Fixture.play(
            [Fixture.control(64, 127, from: Fixture.pads), Fixture.on(60)], on: &shared, routing: merged
        )
        #expect(shared.inputLost(Fixture.keys) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(shared.notes.map(\.sustained) == [true])
        #expect(shared.inputLost(Fixture.pads) == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(shared.notes.isEmpty)
        #expect(shared.pedalHolds.isEmpty)
    }

    @Test
    func fullLedgerRefusesWholePress() throws {
        let policy = try #require(MIDINoteLedgerPolicy(noteCapacity: 3))
        var ledger = MIDINoteLedger(policy: policy)
        let layered = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings))
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try ledger.route(Fixture.on(60), routing: layered)
        Fixture.expectRefused(Fixture.on(62), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 62), in: ledger,
                              routing: layered)
        #expect(try ledger.route(Fixture.on(62), routing: piano) == [Fixture.sentOn(Fixture.piano, 62)])
        _ = try ledger.route(Fixture.off(60), routing: piano)
        #expect(try ledger.route(Fixture.on(64), routing: layered)
            == [Fixture.sentOn(Fixture.piano, 64), Fixture.sentOn(Fixture.strings, 64)])

        // Sustained notes still count: they are never evicted to make room.
        let single = try #require(MIDINoteLedgerPolicy(noteCapacity: 1))
        var held = MIDINoteLedger(policy: single)
        _ = try Fixture.play([Fixture.control(64, 127), Fixture.on(60), Fixture.off(60)], on: &held, routing: piano)
        Fixture.expectRefused(Fixture.on(62), .noteLedgerFull(input: Fixture.keys, channel: 1, note: 62), in: held,
                              routing: piano)
        #expect(try held.route(Fixture.control(64, 0), routing: piano) == [Fixture.sentControl(Fixture.piano, 64, 0)])
        #expect(try held.route(Fixture.on(62), routing: piano) == [Fixture.sentOn(Fixture.piano, 62)])
    }

    @Test
    func fullPedalLedgerRefusesPedalDown() throws {
        let policy = try #require(MIDINoteLedgerPolicy(pedalCapacity: 2))
        var ledger = MIDINoteLedger(policy: policy)
        let routing = try Fixture.routing(
            Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings), Fixture.rule(Fixture.piano, from: Fixture.pads)
        )
        _ = try ledger.route(Fixture.control(64, 127), routing: routing)
        Fixture.expectRefused(Fixture.control(66, 127),
                              .pedalLedgerFull(input: Fixture.keys, channel: 1, pedal: .sostenuto), in: ledger,
                              routing: routing)
        Fixture.expectRefused(Fixture.control(64, 127, from: Fixture.pads),
                              .pedalLedgerFull(input: Fixture.pads, channel: 1, pedal: .sustain), in: ledger,
                              routing: routing)
        #expect(try ledger.route(Fixture.control(64, 100), routing: routing)
            == [Fixture.sentControl(Fixture.piano, 64, 100), Fixture.sentControl(Fixture.strings, 64, 100)])
        // Pedal-ups only remove holds, so they always succeed.
        _ = try ledger.route(Fixture.control(64, 0), routing: routing)
        #expect(try ledger.route(Fixture.control(66, 127), routing: routing)
            == [Fixture.sentControl(Fixture.piano, 66, 127), Fixture.sentControl(Fixture.strings, 66, 127)])
    }

    @Test
    func policyAndRoutingBounds() throws {
        #expect(MIDINoteLedgerPolicy(noteCapacity: 0) == nil)
        #expect(MIDINoteLedgerPolicy(noteCapacity: 4097) == nil)
        #expect(MIDINoteLedgerPolicy(pedalCapacity: 0) == nil)
        #expect(MIDINoteLedgerPolicy(pedalCapacity: 1025) == nil)
        #expect(MIDINoteLedgerPolicy(noteCapacity: 4096, pedalCapacity: 1024) != nil)
        #expect(MIDINoteLedgerPolicy() == .standard)
        #expect(MIDINoteLedgerPolicy.standard.noteCapacity == 1024)
        #expect(MIDINoteLedgerPolicy.standard.pedalCapacity == 256)
        let ledger = MIDINoteLedger()
        #expect(ledger.maximumOutputsPerEvent == 1024 + 256 + 3 * 64)
        #expect(ledger.maximumPanicOutputs == 3 * (1024 + 256))
        #expect(MIDINoteLedger.maximumPanicOutputsPerRoute == 16 * 128 + 16 * 2 + 16 * 2)

        #expect(MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, channels: 0...1) == nil)
        #expect(MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, channels: 16...17) == nil)
        #expect(MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, notes: 0...128) == nil)
        #expect(MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, transpose: 128) == nil)
        #expect(MIDIRoutingRule(input: Fixture.keys, route: Fixture.piano, transpose: -128) == nil)
        let rule = try Fixture.rule(Fixture.piano, channels: 16...16, transpose: -127)
        #expect(rule.transposed(127) == 0)
        #expect(rule.transposed(126) == nil)
        #expect(MIDIRouting(rules: Array(repeating: rule, count: MIDIRouting.maximumRules)) != nil)
        #expect(MIDIRouting(rules: Array(repeating: rule, count: MIDIRouting.maximumRules + 1)) == nil)
    }
}
