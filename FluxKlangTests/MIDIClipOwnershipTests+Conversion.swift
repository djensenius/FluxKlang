import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClipOwnershipTests {
    @Test
    func conversionKeepsOrderInputAndMessageForAMultiNoteClip() throws {
        let items: [MIDIClipItem] = [
            Self.note(0, Self.quarter), Self.note(0, 2 * Self.quarter, pitch: 64, release: 20),
            .event(ticks: Self.quarter, message: .controlChange(channel: 1, controller: 7, value: 90))
        ]
        var scheduler = MIDIClipScheduler(placement: try Self.placement(items))
        let events = try scheduler.render(from: 0, to: 96_000, clock: Self.clock(), current: Self.live)
        let converted = try Self.clipInput().performanceEvents(events)
        let expected: [MIDIPerformanceEvent] = [
            .init(input: Self.clipID, message: Self.on(60)), .init(input: Self.clipID, message: Self.on(64)),
            .init(input: Self.clipID, message: Self.off(60)),
            .init(input: Self.clipID, message: .controlChange(channel: 1, controller: 7, value: 90)),
            .init(input: Self.clipID, message: Self.off(64, velocity: 20))
        ]
        #expect(converted == expected)
    }

    @Test
    func conversionOfNoEventsIsEmptyAndEachClipUsesItsOwnInput() throws {
        let events = [MIDIClipEvent(frame: 5, pass: 0, item: 0, message: Self.on(61))]
        #expect(try Self.clipInput().performanceEvents([]).isEmpty)
        #expect(try Self.clipInput(Self.clipID).performanceEvents(events)
            == [MIDIPerformanceEvent(input: Self.clipID, message: Self.on(61))])
        #expect(try Self.clipInput(Self.otherID).performanceEvents(events)
            == [MIDIPerformanceEvent(input: Self.otherID, message: Self.on(61))])
    }

    @Test
    func renderRoutesTheClipsNotesUnderItsOwnInputOnly() throws {
        var host = try Self.host([Self.note(0, 2 * Self.quarter), Self.note(0, Self.quarter, pitch: 62)],
                                 length: 4 * Self.quarter)
        let report = try Self.render(&host, to: 12_000)
        #expect(report.outputs == [
            MIDIRoutedOutput(route: Self.route1, message: Self.on(60)),
            MIDIRoutedOutput(route: Self.route1, message: Self.on(62))
        ])
        #expect(report.routedEventCount == 2 && report.unownedNoteCount == 0)
        #expect(report.refusals.isEmpty && report.droppedRefusalCount == 0)
        #expect(host.ledger.notes.map(\.input) == [Self.clipID, Self.clipID])
        #expect(host.ownedNotes(of: Self.clipID) == host.ledger.notes)
    }
}
