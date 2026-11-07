import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClipOwnershipTests {
    private static func idle() -> [MIDIClipItem] {
        [note(0, quarter)]
    }

    private static func fullHost() throws -> MIDIClipHost {
        var host = MIDIClipHost(ledger: try Self.ledger())
        for index in 0..<MIDIClipHost.maximumClips {
            try Self.addClip(Self.idle(), id: MIDIInputID(UInt32(100 + index)), in: &host)
        }
        return host
    }

    private static func cc(_ value: UInt8) -> MIDIPerformanceEvent {
        MIDIPerformanceEvent(input: otherID, message: .controlChange(channel: 1, controller: 7, value: value))
    }

    @Test
    func aSecondClipOnTheSameInputIsRefusedAndTheHostIsUnchangedEvenWithAnotherRouting() throws {
        var host = try Self.host(Self.idle())
        _ = try Self.render(&host, to: 100)
        let before = host
        #expect(Self.refusal { try Self.addClip([Self.note(0, 2 * Self.quarter)], id: Self.clipID, in: &host) }
            == .inputAlreadyBound(Self.clipID))
        #expect(Self.refusal { try Self.addClip(Self.idle(), id: Self.clipID, to: [Self.route2], in: &host) }
            == .inputAlreadyBound(Self.clipID))
        #expect(host == before && host.boundInputs == [Self.clipID])
    }

    @Test
    func theSixtyFourthClipIsBoundAndTheSixtyFifthIsRefusedWithTheHostUnchanged() throws {
        var host = try Self.fullHost()
        #expect(host.boundInputs.count == 64 && MIDIClipHost.maximumClips == 64)
        let before = host
        #expect(Self.refusal { try Self.addClip(Self.idle(), id: Self.otherID, in: &host) }
            == .clipLimitReached(limit: 64))
        #expect(host == before)
        // A duplicate is reported before the full host, in either input order.
        #expect(Self.refusal { try Self.addClip(Self.idle(), id: MIDIInputID(100), in: &host) }
            == .inputAlreadyBound(MIDIInputID(100)))
        #expect(Self.refusal { try Self.addClip(Self.idle(), id: MIDIInputID(163), in: &host) }
            == .inputAlreadyBound(MIDIInputID(163)))
        #expect(host == before)
    }

    @Test
    func aClipInputWhoseNotesOrPedalsTheLedgerAlreadyHoldsIsRefusedAfterTheLimitChecks() throws {
        var ledger = try Self.ledger()
        try Self.play(Self.on(60), input: Self.otherID, in: &ledger)
        try Self.play(.controlChange(channel: 1, controller: 64, value: 127), input: Self.thirdID, in: &ledger)
        var host = MIDIClipHost(ledger: ledger)
        let before = host
        for id in [Self.otherID, Self.thirdID] {
            #expect(Self.refusal { try Self.addClip(Self.idle(), id: id, in: &host) } == .inputHoldsLedgerNotes(id))
        }
        #expect(host == before)
        try Self.addClip(Self.idle(), id: Self.clipID, in: &host)
        #expect(host.boundInputs == [Self.clipID])
        var full = try Self.fullHost()
        try Self.play(Self.on(60), input: Self.otherID, in: &full)
        #expect(Self.refusal { try Self.addClip(Self.idle(), id: Self.otherID, in: &full) }
            == .clipLimitReached(limit: 64))
    }

    @Test
    func anInputWithoutAClipIsRefusedByRenderRebindAndStopLeavingTheHostUnchanged() throws {
        var host = try Self.host(Self.idle())
        try Self.play(Self.on(72), input: Self.otherID, in: &host)
        let before = host
        let clock = try Self.clock()
        #expect(Self.refusal { try Self.render(&host, Self.otherID, to: 100) } == .inputNotBound(Self.otherID))
        #expect(Self.refusal { try host.rebind(input: Self.otherID, clock: clock, current: Self.live, atFrame: 0) }
            == .inputNotBound(Self.otherID))
        #expect(Self.refusal { try host.stop(input: Self.otherID) } == .inputNotBound(Self.otherID))
        #expect(host == before)
    }

    @Test
    func aDroneOnAnotherInputSurvivesEveryClipOperationIncludingRefusedOnes() throws {
        var host = MIDIClipHost(ledger: try Self.ledger())
        try Self.play(Self.on(60), input: Self.otherID, in: &host)
        let drone = Self.entries(of: Self.otherID, in: host.ledger)
        try Self.addClip([Self.note(0, 2 * Self.quarter)], id: Self.clipID, in: &host)
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == drone)
        _ = try Self.render(&host, to: 100)
        _ = Self.refusal { try Self.render(&host, from: 500, to: 600) }
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == drone)
        let next = try Self.generations(map: 2)
        try host.rebind(input: Self.clipID, clock: Self.clock(next, frame: 100), current: next, atFrame: 100)
        _ = try host.stop(input: Self.clipID)
        _ = try host.stop(input: Self.clipID)
        #expect(Self.entries(of: Self.otherID, in: host.ledger) == drone)
        #expect(host.ledger.notes == drone)
    }

    @Test
    func aCopiedHostStopsOnlyItsOwnLedgerAndLeavesTheOriginalSounding() throws {
        var original = try Self.host([Self.note(0, 2 * Self.quarter)])
        _ = try Self.render(&original, to: 100)
        let sounding = original.ledger
        var copy = original
        #expect(try copy.stop(input: Self.clipID).outputs.count == 1)
        #expect(original.ledger == sounding && original.ownedNotes(of: Self.clipID).count == 1)
        #expect(copy.ledger.notes.isEmpty)
    }

    @Test
    func passThroughRefusesAnEventOfABoundClipInputAndTheWholeBatchStaysUnapplied() throws {
        var host = try Self.host(Self.idle())
        let before = host
        let routing = try Self.routing(Self.otherID)
        let drone = MIDIPerformanceEvent(input: Self.otherID, message: Self.on(72))
        let clash = MIDIPerformanceEvent(input: Self.clipID, message: Self.on(60))
        let second = MIDIPerformanceEvent(input: Self.clipID, message: Self.on(61))
        let third = MIDIPerformanceEvent(input: Self.thirdID, message: Self.on(62))
        #expect(Self.refusal { try host.routeOther([drone, clash], routing: routing) }
            == .inputBoundToClip(Self.clipID))
        #expect(Self.refusal { try host.routeOther([clash, drone], routing: routing) }
            == .inputBoundToClip(Self.clipID))
        // The first clashing event is reported when several inputs are bound.
        try Self.addClip(Self.idle(), id: Self.thirdID, in: &host)
        let withTwo = host
        let thirdFirst = Self.refusal { try host.routeOther([third, second], routing: routing) }
        let clipFirst = Self.refusal { try host.routeOther([second, third], routing: routing) }
        #expect(thirdFirst == .inputBoundToClip(Self.thirdID))
        #expect(clipFirst == .inputBoundToClip(Self.clipID))
        #expect(host == withTwo && before.boundInputs == [Self.clipID])
    }

    @Test
    func passThroughIsAtomicAndReportsTheFirstLedgerRefusalAfterTheClashCheck() throws {
        var host = try Self.host(Self.idle())
        let routing = try Self.routing(Self.otherID)
        let good = MIDIPerformanceEvent(input: Self.otherID, message: Self.on(72))
        let unowned = MIDIPerformanceEvent(input: Self.otherID, message: Self.off(80))
        let clash = MIDIPerformanceEvent(input: Self.clipID, message: Self.on(60))
        let before = host
        let refusal = Self.refusal { try host.routeOther([good, unowned], routing: routing) }
        #expect(refusal == .ledger(.unownedNote(input: Self.otherID, channel: 1, note: 80)))
        #expect(host == before)
        // A clash is reported before a ledger refusal whichever comes first.
        #expect(Self.refusal { try host.routeOther([unowned, clash], routing: routing) }
            == .inputBoundToClip(Self.clipID))
        #expect(Self.refusal { try host.routeOther([clash, unowned], routing: routing) }
            == .inputBoundToClip(Self.clipID))
        #expect(host == before)
        #expect(try host.routeOther([good], routing: routing)
            == [MIDIRoutedOutput(route: Self.route1, message: Self.on(72))])
    }

    @Test
    func passThroughTakesFourThousandNinetySixEventsAndRefusesOneMoreBeforeTouchingTheLedger() throws {
        var host = try Self.host(Self.idle())
        let routing = try Self.routing(Self.otherID)
        let limit = MIDIClipOwnershipReport.maximumBatchEvents
        let outputs = try host.routeOther((0..<limit).map { Self.cc(UInt8($0 % 100)) }, routing: routing)
        #expect(outputs.count == 4096)
        let before = host
        let tooMany = (0...limit).map { Self.cc(UInt8($0 % 100)) }
        #expect(Self.refusal { try host.routeOther(tooMany, routing: routing) }
            == .ownership(.batchTooLarge(count: 4097, limit: 4096)))
        #expect(host == before)
        // The size is checked before the clash, whichever event order.
        let clash = MIDIPerformanceEvent(input: Self.clipID, message: Self.on(60))
        #expect(Self.refusal { try host.routeOther(tooMany + [clash], routing: routing) }
            == .ownership(.batchTooLarge(count: 4098, limit: 4096)))
        #expect(host == before)
    }
}
