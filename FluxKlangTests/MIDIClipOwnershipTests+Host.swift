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

    /// Two clips on `route1` (inputs `clipID` and `otherID`) over one ledger.
    private static func pairHost(_ first: [MIDIClipItem], _ second: [MIDIClipItem],
                                 second route: MIDIRouteID = route1,
                                 ledger: MIDINoteLedger? = nil) throws -> MIDIClipHost {
        var host = try Self.host(first, ledger: ledger)
        try Self.addClip(second, id: otherID, to: [route], in: &host)
        return host
    }

    private static func together(_ host: inout MIDIClipHost, _ inputs: [MIDIInputID], from start: Int64 = 0,
                                 to end: Int64) throws -> MIDIClipOwnershipReport {
        try host.render(inputs: inputs, from: start, to: end, clock: try Self.clock(), current: live)
    }

    private static func offs(_ report: MIDIClipOwnershipReport) -> [MIDIClipTimedOutput] {
        report.timedOutputs.filter { if case .noteOff = $0.output.message { true } else { false } }
    }

    @Test
    func overlappingNotesOfTwoClipsHoldBackTheFirstNoteOffWhicheverClipComesFirst() throws {
        let held = Self.note(0, Self.quarter, release: 5)
        let later = Self.note(Self.quarter / 2, 2 * Self.quarter, release: 9)
        var results: [(MIDIClipOwnershipReport, MIDIClipHost)] = []
        for order in [[Self.clipID, Self.otherID], [Self.otherID, Self.clipID]] {
            var host = try Self.pairHost([held], [later])
            let report = try Self.together(&host, order, to: 60_000)
            let wire = Self.offs(report)
            #expect(wire.map(\.frame) == [48_000])
            #expect(wire.map(\.output) == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60, velocity: 9))])
            #expect(report.routedEventCount == 4 && report.refusals.isEmpty && report.unownedNoteCount == 0)
            #expect(host.ledger.notes.isEmpty)
            let cursors = [try host.cursor(of: Self.clipID), try host.cursor(of: Self.otherID)]
            #expect(cursors == [60_000, 60_000])
            results.append((report, host))
        }
        let forward = try #require(results.first)
        let swapped = try #require(results.last)
        #expect(forward.0 == swapped.0 && forward.1 == swapped.1)
    }

    @Test
    func separateRendersOfOverlappingClipsSendTheFirstNoteOffEarlyWhichIsWhyTheyMustBeRenderedTogether() throws {
        var host = try Self.pairHost([Self.note(0, Self.quarter, release: 5)],
                                     [Self.note(Self.quarter / 2, 2 * Self.quarter, release: 9)])
        let first = try Self.render(&host, Self.clipID, to: 60_000)
        let second = try Self.render(&host, Self.otherID, to: 60_000)
        #expect(Self.offs(first).map(\.frame) == [24_000] && Self.offs(second).map(\.frame) == [48_000])
    }

    @Test
    func mergedEventsOfTheSameFrameFollowTheListPositionAndKeepEachClipsOwnOrder() throws {
        let firstItems = [Self.note(0, Self.quarter), Self.note(0, Self.quarter, pitch: 64)]
        let secondItems = [Self.note(0, Self.quarter, pitch: 62)]
        for order in [[Self.clipID, Self.otherID], [Self.otherID, Self.clipID]] {
            var host = try Self.pairHost(firstItems, secondItems, second: Self.route2)
            let report = try Self.together(&host, order, to: 12_000)
            let clipOn60 = MIDIRoutedOutput(route: Self.route1, message: Self.on(60))
            let clipOn64 = MIDIRoutedOutput(route: Self.route1, message: Self.on(64))
            let otherOn62 = MIDIRoutedOutput(route: Self.route2, message: Self.on(62))
            let expected = order.first == Self.clipID ? [clipOn60, clipOn64, otherOn62]
                : [otherOn62, clipOn60, clipOn64]
            #expect(report.outputs == expected)
            #expect(report.timedOutputs.map(\.frame) == [0, 0, 0])
        }
    }

    @Test
    func aOneElementInputListEqualsTheSingleInputRenderExactly() throws {
        var single = try Self.pairHost([Self.note(0, Self.quarter)], [Self.note(0, Self.quarter, pitch: 62)])
        var listed = single
        let viaSingle = try Self.render(&single, Self.clipID, to: 30_000)
        let viaList = try Self.together(&listed, [Self.clipID], to: 30_000)
        #expect(viaSingle == viaList && single == listed)
        let cursors = [try listed.cursor(of: Self.clipID), try listed.cursor(of: Self.otherID)]
        #expect(cursors == [30_000, nil])
    }

    @Test
    func anEmptyInputListIsRefusedAndNothingChanges() throws {
        var host = try Self.pairHost([Self.note(0, Self.quarter)], [Self.note(0, Self.quarter, pitch: 62)])
        _ = try Self.together(&host, [Self.clipID], to: 6_000)
        let before = host
        #expect(Self.refusal { try Self.together(&host, [], from: 6_000, to: 12_000) } == .noInputs)
        #expect(host == before)
    }

    @Test
    func aRepeatedInputIsRefusedBeforeAnUnboundOneAndTheFirstRepeatedInListOrderIsNamed() throws {
        var host = try Self.pairHost([Self.note(0, Self.quarter)], [Self.note(0, Self.quarter, pitch: 62)])
        let before = host
        let unbound = Self.thirdID
        #expect(Self.refusal { try Self.together(&host, [unbound, Self.clipID, Self.clipID], to: 6_000) }
            == .inputListedTwice(Self.clipID))
        #expect(Self.refusal { try Self.together(&host, [Self.clipID, Self.clipID, unbound], to: 6_000) }
            == .inputListedTwice(Self.clipID))
        #expect(Self.refusal { try Self.together(&host, [Self.clipID, Self.otherID, Self.otherID, Self.clipID],
                                                 to: 6_000) } == .inputListedTwice(Self.otherID))
        #expect(host == before)
    }

    @Test
    func theFirstUnboundInputInListOrderIsRefusedAndNoListedClipMoves() throws {
        var host = try Self.pairHost([Self.note(0, Self.quarter)], [Self.note(0, Self.quarter, pitch: 62)])
        let before = host
        let unboundA = Self.thirdID
        let unboundB = MIDIInputID(4)
        #expect(Self.refusal { try Self.together(&host, [Self.clipID, unboundA, unboundB], to: 6_000) }
            == .inputNotBound(unboundA))
        #expect(Self.refusal { try Self.together(&host, [Self.clipID, unboundB, unboundA], to: 6_000) }
            == .inputNotBound(unboundB))
        let cursor = try host.cursor(of: Self.clipID)
        #expect(host == before && cursor == nil)
    }

    @Test
    func theFirstClipInListOrderWhoseSchedulerRefusesIsReportedAndEarlierClipsDoNotMove() throws {
        var host = try Self.pairHost([Self.note(0, Self.quarter)], [Self.note(0, Self.quarter, pitch: 62)])
        _ = try Self.render(&host, Self.clipID, to: 12_000)
        _ = try Self.render(&host, Self.otherID, to: 6_000)
        let before = host
        let firstRefuses = MIDIClipHostRefusal.clip(.nonContiguousWindow(expected: 12_000, start: 18_000))
        let secondRefuses = MIDIClipHostRefusal.clip(.nonContiguousWindow(expected: 6_000, start: 18_000))
        #expect(Self.refusal { try Self.together(&host, [Self.clipID, Self.otherID], from: 18_000, to: 24_000) }
            == firstRefuses)
        #expect(Self.refusal { try Self.together(&host, [Self.otherID, Self.clipID], from: 18_000, to: 24_000) }
            == secondRefuses)
        #expect(host == before)
        // Only the SECOND listed clip refuses: the first one's cursor and the ledger stay put.
        #expect(Self.refusal { try Self.together(&host, [Self.clipID, Self.otherID], from: 12_000, to: 24_000) }
            == .clip(.nonContiguousWindow(expected: 6_000, start: 12_000)))
        let cursors = [try host.cursor(of: Self.clipID), try host.cursor(of: Self.otherID)]
        #expect(host == before && cursors == [12_000, 6_000])
    }

    private static func crowd(shortFirst: Bool) -> [MIDIClipItem] {
        (0..<2048).map { (index: Int) -> MIDIClipItem in
            let end: Int64 = shortFirst && index == 0 ? 1_000 : 20_000
            let channel = UInt8(1 + index / 128)
            return .note(MIDIClipNote(channel: channel, note: UInt8(index % 128), velocity: 100,
                                      releaseVelocity: 64, startTicks: Int64(index), endTicks: end))
        }
    }

    @Test
    func aMergedBatchOfFourThousandNinetySixEventsIsRoutedAndOneMoreIsRefusedWholeAcrossTwoClips() throws {
        let big = try Self.ledger(noteCapacity: 4096)
        var host = try Self.pairHost(Self.crowd(shortFirst: false), Self.crowd(shortFirst: false), ledger: big)
        let full = try Self.together(&host, [Self.clipID, Self.otherID], to: 4_000)
        #expect(full.routedEventCount == 4096 && full.refusals.isEmpty && host.ledger.notes.count == 4096)
        var over = try Self.pairHost(Self.crowd(shortFirst: false), Self.crowd(shortFirst: true), ledger: big)
        let before = over
        #expect(Self.refusal { try Self.together(&over, [Self.clipID, Self.otherID], to: 4_000) }
            == .ownership(.batchTooLarge(count: 4097, limit: 4096)))
        let cursor = try over.cursor(of: Self.clipID)
        #expect(over == before && cursor == nil && over.ledger.notes.isEmpty)
    }

    @Test
    func aLedgerRefusalInAMergedBatchNamesTheClipOfTheEventAndItsMergedIndex() throws {
        let tight = try Self.ledger(noteCapacity: 1)
        for order in [[Self.clipID, Self.otherID], [Self.otherID, Self.clipID]] {
            var host = try Self.pairHost([Self.note(0, Self.quarter)], [Self.note(0, Self.quarter, pitch: 62)],
                                         ledger: tight)
            let report = try Self.together(&host, order, to: 30_000)
            let refused = try #require(report.refusals.first)
            #expect(report.refusals.count == 1 && refused.index == 1 && report.routedEventCount == 4)
            #expect(refused.input == order[1] && report.unownedNoteCount == 1)
        }
    }

    @Test
    func aLaterEventOfAnotherClipKeepsItsOwnFrameAfterAnEarlierClipsRefusedEvent() throws {
        let tight = try Self.ledger(noteCapacity: 1)
        var host = try Self.pairHost([Self.note(0, Self.quarter)],
                                     [Self.note(Self.quarter / 4, Self.quarter, pitch: 62)], ledger: tight)
        let report = try Self.together(&host, [Self.otherID, Self.clipID], to: 30_000)
        let refused = try #require(report.refusals.first)
        #expect(refused.input == Self.otherID && refused.index == 1 && refused.event.frame == 6_000)
        #expect(report.timedOutputs.map(\.frame) == [0, 24_000])
    }
}
