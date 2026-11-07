import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClipOwnershipTests {
    private static func fullLedger() throws -> MIDINoteLedger {
        var ledger = try Self.ledger(noteCapacity: 1)
        try Self.play(Self.on(1), input: Self.otherID, in: &ledger)
        return ledger
    }

    private static func eventOn(_ pitch: UInt8 = 60, at frame: Int64 = 0) -> MIDIClipEvent {
        MIDIClipEvent(frame: frame, pass: 0, item: 0, message: Self.on(pitch))
    }

    private static func eventOff(_ pitch: UInt8 = 60, at frame: Int64 = 0) -> MIDIClipEvent {
        MIDIClipEvent(frame: frame, pass: 0, item: 0, message: Self.off(pitch))
    }

    private static func routed(_ events: [MIDIClipEvent], in ledger: inout MIDINoteLedger) throws
        -> MIDIClipOwnershipReport {
        try MIDIClipOwnershipReport.route(events, through: try Self.clipInput(), ledger: &ledger)
    }

    @Test
    func aSchedulerRefusalChangesNeitherPlaybackNorLedgerAndTheGapComesFirst() throws {
        var host = try Self.host([Self.note(0, 2 * Self.quarter)])
        _ = try Self.render(&host, to: 100)
        let before = host
        let revised = try Self.generations(map: 2)
        // A gap and a stale generation together: the gap is reported.
        let gap = Self.refusal {
            try Self.render(&host, from: 200, to: 300, clock: Self.clock(revised), current: revised)
        }
        #expect(gap == .clip(.nonContiguousWindow(expected: 100, start: 200)))
        let stale = Self.refusal {
            try Self.render(&host, from: 100, to: 300, clock: Self.clock(revised), current: revised)
        }
        #expect(stale == .clip(.clockRevisionChanged(expected: Self.live, got: revised)))
        #expect(host == before)
    }

    @Test
    func aLedgerRefusalIsReportedWithoutAbortingTheLaterEventsOfTheBatch() throws {
        let volume = MIDIClipItem.event(ticks: 1000, message: .controlChange(channel: 1, controller: 7, value: 90))
        let items = [Self.note(0, 2 * Self.quarter), Self.note(0, 2 * Self.quarter, pitch: 64), volume]
        var host = try Self.host(items, ledger: Self.ledger(noteCapacity: 1))
        let report = try Self.render(&host, to: 12_000)
        #expect(report.outputs == [
            MIDIRoutedOutput(route: Self.route1, message: Self.on(60)),
            MIDIRoutedOutput(route: Self.route1, message: .controlChange(channel: 1, controller: 7, value: 90))
        ])
        let refused = try #require(report.refusals.first)
        #expect(report.refusals.count == 1 && refused.index == 1)
        #expect(refused.event == MIDIClipEvent(frame: 0, pass: 0, item: 1, message: Self.on(64)))
        #expect(refused.refusal == .noteLedgerFull(input: Self.clipID, channel: 1, note: 64))
        #expect(report.routedEventCount == 3 && host.ledger.notes.count == 1)
        // The refused note still sounds for the scheduler: its Note Off is benign and counted.
        let stopped = try host.stop(input: Self.clipID)
        #expect(stopped.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.off(60))])
        #expect(stopped.unownedNoteCount == 1 && stopped.refusals.isEmpty && host.ledger.notes.isEmpty)
    }

    @Test
    func aRefusedEventLeavesTheLedgerUnchanged() throws {
        var ledger = try Self.fullLedger()
        let before = ledger
        let report = try Self.routed([Self.eventOn()], in: &ledger)
        #expect(report.refusals.map(\.refusal) == [.noteLedgerFull(input: Self.clipID, channel: 1, note: 60)])
        #expect(report.outputs.isEmpty && ledger == before)
    }

    @Test
    func theReportKeepsTwoHundredFiftySixRefusalsAndCountsNoneDropped() throws {
        var ledger = try Self.fullLedger()
        let events = (0..<MIDIClipOwnershipReport.maximumRefusals).map { Self.eventOn(at: Int64($0)) }
        let report = try Self.routed(events, in: &ledger)
        #expect(report.refusals.count == 256 && report.droppedRefusalCount == 0 && report.routedEventCount == 256)
        #expect(report.refusals.map(\.index) == Array(0..<256))
    }

    @Test
    func theReportDropsTheTwoHundredFiftySeventhRefusalAndCountsIt() throws {
        var ledger = try Self.fullLedger()
        let events = (0...MIDIClipOwnershipReport.maximumRefusals).map { Self.eventOn(at: Int64($0)) }
        let report = try Self.routed(events, in: &ledger)
        #expect(report.refusals.count == 256 && report.droppedRefusalCount == 1 && report.routedEventCount == 257)
        #expect(report.refusals.map(\.index) == Array(0..<256))
        #expect(report.refusals.last?.event.frame == 255)
        #expect(report.unownedNoteCount == 0 && report.outputs.isEmpty)
    }

    @Test
    func aBatchOfFourThousandNinetySixEventsIsRoutedAndOneMoreIsRefusedBeforeTheLedgerIsTouched() throws {
        let limit = MIDIClipOwnershipReport.maximumBatchEvents
        var ledger = try Self.fullLedger()
        let full = try Self.routed((0..<limit).map { Self.eventOn(at: Int64($0)) }, in: &ledger)
        #expect(limit == 4096 && full.routedEventCount == 4096 && full.droppedRefusalCount == 4096 - 256)
        let before = ledger
        let tooMany = (0...limit).map { Self.eventOn(at: Int64($0)) }
        #expect(throws: MIDIClipOwnershipRefusal.batchTooLarge(count: 4097, limit: 4096)) {
            try Self.routed(tooMany, in: &ledger)
        }
        #expect(ledger == before)
        // An over-long batch of events the ledger would accept is refused whole as well: nothing sounds.
        var empty = try Self.ledger()
        let pristine = empty
        let acceptable = (0...limit).map { Self.eventOn(UInt8($0 % 100), at: Int64($0)) }
        #expect(throws: MIDIClipOwnershipRefusal.batchTooLarge(count: 4097, limit: 4096)) {
            try Self.routed(acceptable, in: &empty)
        }
        #expect(empty == pristine)
    }

    @Test
    func benignUnownedNotesAreCountedAndNeverUseUpTheRefusalBound() throws {
        var ledger = try Self.fullLedger()
        let unowned = (0..<300).map { Self.eventOff(at: Int64($0)) }
        let report = try Self.routed(unowned + [Self.eventOn(at: 300)], in: &ledger)
        #expect(report.unownedNoteCount == 300 && report.droppedRefusalCount == 0)
        #expect(report.refusals.map(\.index) == [300] && report.routedEventCount == 301)
    }

    @Test
    func refusalsAndUnownedNotesAreReportedInEventOrderWhicheverComesFirst() throws {
        for refusedFirst in [true, false] {
            var ledger = try Self.fullLedger()
            let events = refusedFirst ? [Self.eventOn(), Self.eventOff(61)] : [Self.eventOff(61), Self.eventOn()]
            let report = try Self.routed(events, in: &ledger)
            #expect(report.unownedNoteCount == 1 && report.refusals.map(\.index) == [refusedFirst ? 0 : 1])
            #expect(report.refusals.first?.event == Self.eventOn())
        }
    }

    @Test
    func malformedAndSystemEventsAreRecordedAsRefusalsInOrder() throws {
        var ledger = try Self.ledger()
        let bad = MIDIClipEvent(frame: 0, pass: 0, item: 0, message: .noteOn(channel: 17, note: 60, velocity: 100))
        let system = MIDIClipEvent(frame: 1, pass: 0, item: 1, message: .realTime(status: 0xF8))
        let before = ledger
        let report = try Self.routed([bad, system, Self.eventOn(at: 2)], in: &ledger)
        #expect(report.refusals.map(\.refusal) == [.malformedEvent, .systemMessage])
        #expect(report.refusals.map(\.index) == [0, 1] && report.routedEventCount == 3)
        #expect(report.outputs == [MIDIRoutedOutput(route: Self.route1, message: Self.on(60))] && ledger != before)
    }
}
