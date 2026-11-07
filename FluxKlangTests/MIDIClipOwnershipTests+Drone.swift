import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClipOwnershipTests {
    /// Starts one clip note (60, a half-note of 120 BPM) and a drone of another input, and returns the host.
    private static func sounding(drone droneNote: UInt8, route: MIDIRouteID) throws -> MIDIClipHost {
        var host = MIDIClipHost(ledger: try Self.ledger())
        try Self.play(Self.on(droneNote), input: Self.otherID, to: [route], in: &host)
        try Self.addClip([Self.note(0, 2 * Self.quarter, release: 33)], id: Self.clipID, in: &host)
        _ = try Self.render(&host, to: 12_000)
        return host
    }

    @Test
    func stoppingAClipLeavesADroneOnTheSameRouteAndChannelSounding() throws {
        var host = try Self.sounding(drone: 72, route: Self.route1)
        let droneBefore = Self.entries(of: Self.otherID, in: host.ledger)
        #expect(droneBefore.count == 1 && host.ownedNotes(of: Self.clipID).count == 1)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60, velocity: 33))])
        #expect(host.ownedNotes(of: Self.clipID).isEmpty)
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == droneBefore)
    }

    @Test
    func stoppingAClipLeavesADroneOnAnotherRouteSounding() throws {
        var host = try Self.sounding(drone: 60, route: Self.route2)
        let droneBefore = Self.entries(of: Self.otherID, in: host.ledger)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60, velocity: 33))])
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == droneBefore)
        #expect(droneBefore.map(\.route) == [Self.route2])
        #expect(host.ownedNotes(of: Self.clipID).isEmpty)
    }

    @Test
    func aDroneOnTheSameNoteAndDestinationKeepsItsEntryWhenTheClipStops() throws {
        var host = try Self.sounding(drone: 60, route: Self.route1)
        let droneBefore = Self.entries(of: Self.otherID, in: host.ledger)
        #expect(droneBefore.count == 1 && droneBefore.first?.keyDown == true)
        let stopped = try host.stop(input: Self.clipID)
        // The destination note stays on for the drone: the clip's Note Off is held back by the ledger.
        #expect(stopped.outputs.isEmpty && stopped.unownedNoteCount == 0 && stopped.refusals.isEmpty)
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == droneBefore)
        #expect(host.ownedNotes(of: Self.clipID).isEmpty)
        #expect(try Self.play(Self.off(60), input: Self.otherID, in: &host)
            == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60))])
    }

    @Test
    func stoppingTwiceReleasesOnceAndAStopBeforeAnyRenderRoutesNothing() throws {
        var host = try Self.sounding(drone: 72, route: Self.route1)
        #expect(try host.stop(input: Self.clipID).outputs.count == 1)
        let after = host
        let again = try host.stop(input: Self.clipID)
        #expect(again.routedEventCount == 0 && again.outputs.isEmpty && again.unownedNoteCount == 0)
        #expect(host == after)
        var fresh = try Self.host([Self.note(0, Self.quarter)])
        let pristine = fresh
        #expect(try fresh.stop(input: Self.clipID).routedEventCount == 0 && fresh == pristine)
    }

    @Test
    func stoppingMidNoteCarriesTheClipsOwnReleaseVelocity() throws {
        var host = try Self.host([Self.note(0, 2 * Self.quarter, release: 5)], to: [Self.route2])
        _ = try Self.render(&host, to: 30_000)
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route2, message: Self.off(60, velocity: 5))])
    }

    @Test
    func twoClipsOnTwoInputsStopIndependentlyInEitherCallOrder() throws {
        for stopFirst in [Self.clipID, Self.otherID] {
            var host = try Self.host([Self.note(0, 2 * Self.quarter, pitch: 60)], id: Self.clipID)
            try Self.addClip([Self.note(0, 2 * Self.quarter, pitch: 60)], id: Self.otherID, in: &host)
            _ = try Self.render(&host, Self.clipID, to: 100)
            _ = try Self.render(&host, Self.otherID, to: 100)
            let secondBefore = Self.entries(of: Self.otherID, in: host.ledger)
            let firstBefore = Self.entries(of: Self.clipID, in: host.ledger)
            #expect(firstBefore.count == 1 && secondBefore.count == 1)
            if stopFirst == Self.clipID {
                _ = try host.stop(input: Self.clipID)
                #expect(Self.entries(of: Self.otherID, in: host.ledger) == secondBefore)
                #expect(Self.entries(of: Self.clipID, in: host.ledger).isEmpty)
                _ = try host.stop(input: Self.otherID)
            } else {
                _ = try host.stop(input: Self.otherID)
                #expect(Self.entries(of: Self.clipID, in: host.ledger) == firstBefore)
                #expect(Self.entries(of: Self.otherID, in: host.ledger).isEmpty)
                _ = try host.stop(input: Self.clipID)
            }
            #expect(host.ledger.notes.isEmpty)
        }
    }

    @Test
    func stoppingTwoClipsThatShareANoteEmitsOneNoteOffFromTheLastStopInEitherOrder() throws {
        let release = [Self.clipID: UInt8(33), Self.otherID: UInt8(44)]
        for order in [[Self.clipID, Self.otherID], [Self.otherID, Self.clipID]] {
            var host = try Self.host([Self.note(0, 2 * Self.quarter, release: 33)], id: Self.clipID)
            try Self.addClip([Self.note(0, 2 * Self.quarter, release: 44)], id: Self.otherID, in: &host)
            _ = try Self.render(&host, Self.clipID, to: 100)
            _ = try Self.render(&host, Self.otherID, to: 100)
            let first = try #require(order.first)
            let last = try #require(order.last)
            let lastBefore = Self.entries(of: last, in: host.ledger)
            #expect(lastBefore.count == 1)
            let early = try host.stop(input: first)
            #expect(early.outputs.isEmpty && early.refusals.isEmpty && early.unownedNoteCount == 0)
            #expect(Self.entries(of: first, in: host.ledger).isEmpty)
            #expect(Self.entries(of: last, in: host.ledger) == lastBefore)
            let lastRelease = try #require(release[last])
            let final = try host.stop(input: last)
            let expected = MIDIRoutedOutput(route: Self.route1, message: Self.off(60, velocity: lastRelease))
            #expect(final.outputs == [expected])
            #expect(host.ledger.notes.isEmpty)
        }
    }

    @Test
    func aPedalHeldByAnotherInputSustainsTheClipsNoteAndItsReleaseFollowsThePedal() throws {
        var host = MIDIClipHost(ledger: try Self.ledger())
        let pedalDown = MIDI1Semantic.controlChange(channel: 1, controller: 64, value: 127)
        try Self.play(pedalDown, input: Self.otherID, in: &host)
        try Self.addClip([Self.note(0, 2 * Self.quarter)], id: Self.clipID, in: &host)
        _ = try Self.render(&host, to: 12_000)
        let pedalBefore = host.ledger.pedalHolds
        let stopped = try host.stop(input: Self.clipID)
        // The ledger still sends the clip's Note Off; the destination's sustain pedal (another input's) holds the note,
        // so the clip's remaining entry is key-up and sustained until that pedal goes up.
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60))])
        #expect(stopped.refusals.isEmpty && stopped.unownedNoteCount == 0)
        let held = host.ownedNotes(of: Self.clipID)
        #expect(held.count == 1 && held.first?.keyDown == false && held.first?.sustained == true)
        #expect(host.ledger.pedalHolds == pedalBefore && host.ledger.pedalHolds.map(\.input) == [Self.otherID])
        let pedalUp = MIDI1Semantic.controlChange(channel: 1, controller: 64, value: 0)
        #expect(try Self.play(pedalUp, input: Self.otherID, in: &host)
            == [MIDIRoutedOutput(route: Self.route1, message: pedalUp)])
        #expect(host.ownedNotes(of: Self.clipID).isEmpty && host.ledger.pedalHolds.isEmpty)
    }

    @Test
    func withNoForeignPedalAStopLeavesTheClipInputWithNoEntriesAtAll() throws {
        var host = try Self.sounding(drone: 72, route: Self.route1)
        #expect(host.ledger.pedalHolds.isEmpty && host.ownedNotes(of: Self.clipID).count == 1)
        _ = try host.stop(input: Self.clipID)
        #expect(host.ownedNotes(of: Self.clipID).isEmpty)
        #expect(host.ledger.notes.map(\.input) == [Self.otherID])
    }

    @Test
    func stopNeverTouchesAnotherInputsPedalsMarkersOrNotes() throws {
        var host = MIDIClipHost(ledger: try Self.ledger())
        try Self.play(Self.on(72), input: Self.otherID, in: &host)
        try Self.play(Self.on(74), input: Self.thirdID, to: [Self.route2], in: &host)
        try Self.play(.controlChange(channel: 2, controller: 64, value: 127), input: Self.otherID, in: &host)
        try Self.addClip([Self.note(0, 2 * Self.quarter), Self.note(0, Self.quarter, pitch: 62)],
                         id: Self.clipID, in: &host)
        _ = try Self.render(&host, to: 12_000)
        let others = host.ledger.notes.filter { $0.input != Self.clipID }
        let pedals = host.ledger.pedalHolds
        let markers = host.ledger.releaseMarkers
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs.map(\.message) == [Self.off(60), Self.off(62)])
        let ledger = host.ledger
        #expect(ledger.notes == others && ledger.pedalHolds == pedals && ledger.releaseMarkers == markers)
    }
}
