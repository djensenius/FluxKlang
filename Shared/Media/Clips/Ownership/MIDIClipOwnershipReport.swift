//
//  MIDIClipOwnershipReport.swift
//  FluxKlang
//
//  What routing clip events through the note ledger produced (#112 CL9). Every event is routed under the clip's
//  own input, in order. A ledger refusal of one event never aborts the rest: an `.unownedNote` refusal of a note
//  release (Note Off, or Note On with velocity 0) is benign and counted, any other refusal (a poly pressure of an
//  unowned note included) is recorded (the first `maximumRefusals`, then counted as dropped). Every output keeps the
//  scheduled frame of the clip event that produced it.
//

/// One output of a routed clip event with the frame the scheduler gave that event.
struct MIDIClipTimedOutput: Equatable, Sendable {
    /// `MIDIClipEvent.frame` of the event that produced `output`.
    let frame: Int64
    let output: MIDIRoutedOutput

    fileprivate init(frame: Int64, output: MIDIRoutedOutput) {
        self.frame = frame
        self.output = output
    }
}

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

    /// What to send and when, in event order and, within an event, in the ledger's rule order. Every output of one
    /// event carries that event's frame; a refused event contributes nothing.
    private(set) var timedOutputs: [MIDIClipTimedOutput] = []
    /// The events offered to the ledger, accepted or refused.
    private(set) var routedEventCount = 0
    /// Release events refused with the benign `.unownedNote`: a Note Off, or a Note On with velocity 0, of a note
    /// the ledger holds no key for. An `.unownedNote` refusal of any other message is listed in `refusals`.
    private(set) var unownedNoteCount = 0
    /// The first `maximumRefusals` other refusals, in event order.
    private(set) var refusals: [MIDIClipOwnershipRefusedEvent] = []
    /// Other refusals beyond `maximumRefusals`.
    private(set) var droppedRefusalCount = 0

    /// The message-only view of `timedOutputs`.
    var outputs: [MIDIRoutedOutput] { timedOutputs.map(\.output) }

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
            var scratch: [MIDIRoutedOutput] = []
            do {
                try ledger.route(performance, routing: input.routing, into: &scratch)
                report.timedOutputs += scratch.map { MIDIClipTimedOutput(frame: event.frame, output: $0) }
            } catch {
                report.record(error, index: index, event: event)
            }
        }
        return report
    }

    private static func isRelease(_ message: MIDI1Semantic) -> Bool {
        switch message {
        case .noteOff, .noteOn(channel: _, note: _, velocity: 0):
            true
        default:
            false
        }
    }

    private mutating func record(_ refusal: MIDIPerformanceRefusal, index: Int, event: MIDIClipEvent) {
        if case .unownedNote = refusal, Self.isRelease(event.message) {
            unownedNoteCount += 1
        } else if refusals.count < Self.maximumRefusals {
            refusals.append(MIDIClipOwnershipRefusedEvent(index: index, event: event, refusal: refusal))
        } else {
            droppedRefusalCount += 1
        }
    }
}
