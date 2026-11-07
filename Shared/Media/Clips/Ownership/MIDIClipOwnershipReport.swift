//
//  MIDIClipOwnershipReport.swift
//  FluxKlang
//
//  What routing clip events through the note ledger produced (#112 CL9). Every event is routed under the clip's
//  own input, in order. A ledger refusal of one event never aborts the rest: a benign `.unownedNote` is counted, any
//  other refusal is recorded (the first `maximumRefusals`, then counted as dropped).
//

/// One clip event the ledger refused, with its position in the routed batch.
struct MIDIClipOwnershipRefusedEvent: Equatable, Sendable {
    let index: Int
    let event: MIDIClipEvent
    let refusal: MIDIPerformanceRefusal

    fileprivate init(index: Int, event: MIDIClipEvent, refusal: MIDIPerformanceRefusal) {
        self.index = index
        self.event = event
        self.refusal = refusal
    }
}

/// The result of one routed batch. Only `route` builds one.
struct MIDIClipOwnershipReport: Equatable, Sendable {
    /// The most non-benign refusals kept; the rest are counted in `droppedRefusalCount`.
    static let maximumRefusals = 256
    /// The most events one batch may hold: the scheduler's own per-render cap, so a render never exceeds it.
    static let maximumBatchEvents = MIDIClipPlacement.maximumEvents

    /// What to send, in event order and, within an event, in the ledger's rule order.
    private(set) var outputs: [MIDIRoutedOutput] = []
    /// The events offered to the ledger, accepted or refused.
    private(set) var routedEventCount = 0
    /// Events refused with the benign `.unownedNote`: a Note Off of a note the ledger holds no key for.
    private(set) var unownedNoteCount = 0
    /// The first `maximumRefusals` other refusals, in event order.
    private(set) var refusals: [MIDIClipOwnershipRefusedEvent] = []
    /// Other refusals beyond `maximumRefusals`.
    private(set) var droppedRefusalCount = 0

    private init() {}

    /// Routes `events` one by one under `input`'s own identity and routing. A refused event changes nothing in the
    /// ledger (`MIDINoteLedger.route` is atomic per event) and later events are still routed. A batch longer than
    /// `maximumBatchEvents` is refused before the ledger is touched.
    static func route(
        _ events: [MIDIClipEvent], through input: MIDIClipInput, ledger: inout MIDINoteLedger
    ) throws(MIDIClipOwnershipRefusal) -> MIDIClipOwnershipReport {
        guard events.count <= maximumBatchEvents else {
            throw .batchTooLarge(count: events.count, limit: maximumBatchEvents)
        }
        var report = MIDIClipOwnershipReport()
        for (index, (event, performance)) in zip(events, input.performanceEvents(events)).enumerated() {
            report.routedEventCount += 1
            do {
                try ledger.route(performance, routing: input.routing, into: &report.outputs)
            } catch {
                report.record(error, index: index, event: event)
            }
        }
        return report
    }

    private mutating func record(_ refusal: MIDIPerformanceRefusal, index: Int, event: MIDIClipEvent) {
        if case .unownedNote = refusal {
            unownedNoteCount += 1
        } else if refusals.count < Self.maximumRefusals {
            refusals.append(MIDIClipOwnershipRefusedEvent(index: index, event: event, refusal: refusal))
        } else {
            droppedRefusalCount += 1
        }
    }
}
