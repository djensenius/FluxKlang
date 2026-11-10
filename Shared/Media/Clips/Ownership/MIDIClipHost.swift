//
//  MIDIClipHost.swift
//  FluxKlang
//
//  Clips playing as performance inputs, sharing one note ledger (#112 CL9). The host OWNS the ledger and every
//  clip's scheduler and hands out no playback value: each operation names a clip by its `MIDIInputID`. That makes
//  the identity exclusive (one clip per input, no copy of a clip to stop twice or against another ledger) and the
//  ledger binding fixed (a clip is only ever routed into this host's ledger). A clip's stop is its scheduler's own
//  Note Offs routed under the clip's input: never a panic, an input loss or a route loss, which are broader than the
//  clip's ownership. Another input's notes (a drone) therefore survive every clip operation. Clips that can share a
//  destination, channel and note are rendered together (`render(inputs:)`): their events are merged by frame before
//  the ledger sees them, so a held-back Note Off follows the scheduled frames and not the call order.
//

/// Why a host operation was refused. A refusal leaves the whole host (ledger and every clip) unchanged.
enum MIDIClipHostRefusal: Error, Equatable, Sendable {
    /// A clip is already bound to this input.
    case inputAlreadyBound(MIDIInputID)
    /// The host already holds `limit` clips.
    case clipLimitReached(limit: Int)
    /// The ledger already holds release markers of this input: a marker older than the clip's presses would swallow
    /// the clip's own Note Off and leave its key-down entry in the ledger.
    case inputHoldsReleaseMarkers(MIDIInputID)
    /// The ledger already holds notes or pedals of this input, which a clip's stop would release as its own.
    case inputHoldsLedgerNotes(MIDIInputID)
    /// No clip is bound to this input.
    case inputNotBound(MIDIInputID)
    /// A pass-through event carries the input of a bound clip.
    case inputBoundToClip(MIDIInputID)
    /// A multi-clip render was given no inputs.
    case noInputs
    /// A multi-clip render listed `count` inputs, exceeding `limit`, before any input was resolved.
    case inputListTooLarge(count: Int, limit: Int)
    /// A multi-clip render listed this input twice (the first repeated input, in list order).
    case inputListedTwice(MIDIInputID)
    /// The clip's scheduler refused.
    case clip(MIDIClipRefusal)
    /// The batch was refused before the ledger was touched.
    case ownership(MIDIClipOwnershipRefusal)
    /// The ledger refused a pass-through event.
    case ledger(MIDIPerformanceRefusal)
}

/// One note ledger plus the clips (at most `maximumClips`, one per input) that play into it.
struct MIDIClipHost: Equatable, Sendable {
    /// The most clips one host binds or lists in a render.
    static let maximumClips = 64

    /// The shared ledger, read-only: it changes only through the host's operations.
    private(set) var ledger: MIDINoteLedger
    private var clips: [BoundClip] = []

    private struct BoundClip: Equatable, Sendable {
        let input: MIDIClipInput
        var scheduler: MIDIClipScheduler
    }

    /// A host over `ledger`, which may already hold other inputs' notes.
    init(ledger: MIDINoteLedger = MIDINoteLedger()) {
        self.ledger = ledger
    }

    /// The inputs with a bound clip, in binding order.
    var boundInputs: [MIDIInputID] { clips.map { $0.input.input } }

    /// The ledger's entries of `input`, in ledger order.
    func ownedNotes(of input: MIDIInputID) -> [MIDINoteInstance] {
        ledger.notes.filter { $0.input == input }
    }

    /// Binds a clip. Refusals, in this order: an input that already has a clip, a full host, an input the ledger
    /// holds release markers for, an input the ledger already holds notes or pedals for. A refusal changes nothing.
    mutating func add(_ input: MIDIClipInput, placement: MIDIClipPlacement) throws(MIDIClipHostRefusal) {
        let id = input.input
        guard !boundInputs.contains(id) else { throw .inputAlreadyBound(id) }
        guard clips.count < Self.maximumClips else { throw .clipLimitReached(limit: Self.maximumClips) }
        guard !ledger.releaseMarkers.contains(where: { $0.input == id }) else { throw .inputHoldsReleaseMarkers(id) }
        guard !ledger.notes.contains(where: { $0.input == id }), !ledger.pedalHolds.contains(where: { $0.input == id })
        else { throw .inputHoldsLedgerNotes(id) }
        clips.append(BoundClip(input: input, scheduler: MIDIClipScheduler(placement: placement)))
    }

    /// Renders the clip of `input` over `[start, end)` and routes its events into the ledger: exactly
    /// `render(inputs: [input], ...)`. Clips that can share a destination, channel and note must be rendered
    /// TOGETHER in one `render(inputs:)` call: separate calls route one clip's whole window before the next one's,
    /// so a shared note's release decision would depend on call order instead of scheduled frames.
    mutating func render(
        input: MIDIInputID, from start: Int64, to end: Int64, clock: MusicalClockMap, current: MIDIClipGenerations
    ) throws(MIDIClipHostRefusal) -> MIDIClipOwnershipReport {
        try render(inputs: [input], from: start, to: end, clock: clock, current: current)
    }

    /// Renders every listed clip over the same window `[start, end)` (each scheduler on a copy), merges all their
    /// events into ONE sequence ordered by (frame, the clip's position in `inputs`, the event's index within its
    /// clip) and routes it once through the shared ledger, each event under its own clip's input and routing. A
    /// per-event ledger refusal is reported without aborting the rest. All-or-nothing: the ledger and every
    /// scheduler are committed only after the whole batch is known to be accepted. Refusals, in this order: an
    /// empty list, a list over `maximumClips`, the first input listed twice, the first unbound input, the first
    /// clip (in list order) whose scheduler refuses, a merged batch over `MIDIClipOwnershipReport.maximumBatchEvents`.
    /// A refusal changes nothing.
    mutating func render(
        inputs: [MIDIInputID], from start: Int64, to end: Int64, clock: MusicalClockMap,
        current: MIDIClipGenerations
    ) throws(MIDIClipHostRefusal) -> MIDIClipOwnershipReport {
        let slots = try slots(of: inputs)
        var schedulers: [MIDIClipScheduler] = []
        var merged: [MergedEvent] = []
        for (position, slot) in slots.enumerated() {
            var scheduler = clips[slot].scheduler
            do throws(MIDIClipRefusal) {
                let events = try scheduler.render(from: start, to: end, clock: clock, current: current)
                for (index, event) in events.enumerated() {
                    merged.append(MergedEvent(position: position, index: index, sourced: MIDIClipSourcedEvent(
                        event: event, clip: clips[slot].input
                    )))
                }
            } catch {
                throw .clip(error)
            }
            schedulers.append(scheduler)
        }
        merged.sort()
        var working = ledger
        let report = try route(merged.map(\.sourced), ledger: &working)
        ledger = working
        for (slot, scheduler) in zip(slots, schedulers) { clips[slot].scheduler = scheduler }
        return report
    }

    /// One clip event in the merge, ordered by (frame, clip position in the list, index within the clip).
    private struct MergedEvent: Comparable {
        let position: Int
        let index: Int
        let sourced: MIDIClipSourcedEvent

        static func < (lhs: MergedEvent, rhs: MergedEvent) -> Bool {
            (lhs.sourced.event.frame, lhs.position, lhs.index) < (rhs.sourced.event.frame, rhs.position, rhs.index)
        }

        static func == (lhs: MergedEvent, rhs: MergedEvent) -> Bool {
            lhs.position == rhs.position && lhs.index == rhs.index && lhs.sourced == rhs.sourced
        }
    }

    /// The frame the next render of `input` must start at: the end of its last render, or the cursor a `rebind`
    /// moved. Nil before the first render and after `stop`.
    func cursor(of input: MIDIInputID) throws(MIDIClipHostRefusal) -> Int64? {
        let slot = try slot(of: input)
        return clips[slot].scheduler.cursor
    }

    /// Rebinds the clip of `input` to a revised clock at `frame`, which must equal `cursor(of:)`. The ledger is
    /// never touched. The cursor may MOVE: the next render must start at `cursor(of:)`, which can differ from
    /// `frame`, or it is refused as `.nonContiguousWindow`.
    mutating func rebind(
        input: MIDIInputID, clock: MusicalClockMap, current: MIDIClipGenerations, atFrame frame: Int64
    ) throws(MIDIClipHostRefusal) {
        let slot = try slot(of: input)
        var scheduler = clips[slot].scheduler
        do throws(MIDIClipRefusal) {
            try scheduler.rebind(clock: clock, current: current, atFrame: frame)
        } catch {
            throw .clip(error)
        }
        clips[slot].scheduler = scheduler
    }

    /// Stops the clip of `input`: the Note Offs of the notes it sounds, routed under its own input. Other inputs'
    /// entries are never touched. A Note Off the ledger holds back (another input holds the same note or a pedal)
    /// leaves that other input's state alone. A stop emits one Note Off per sounding note and a rebind none. A clip
    /// refuses overlapping notes of one channel and note, so at most 16 channels * 128 notes = 2,048 notes sound
    /// at once: always within `maximumBatchEvents` (4,096), so the stop is never refused for its size.
    mutating func stop(input: MIDIInputID) throws(MIDIClipHostRefusal) -> MIDIClipOwnershipReport {
        let slot = try slot(of: input)
        var scheduler = clips[slot].scheduler
        let report = try route(scheduler.stop(), slot: slot)
        clips[slot].scheduler = scheduler
        return report
    }

    /// Routes live events of inputs that have no clip (a drone, a pedal) through `routing` into the ledger. The
    /// whole batch is atomic: any refusal leaves the ledger unchanged. Refusals, in this order: a batch over
    /// `MIDIClipOwnershipReport.maximumBatchEvents`, the first event whose input has a bound clip, the first
    /// ledger refusal in event order.
    mutating func routeOther(
        _ events: [MIDIPerformanceEvent], routing: MIDIRouting
    ) throws(MIDIClipHostRefusal) -> [MIDIRoutedOutput] {
        let limit = MIDIClipOwnershipReport.maximumBatchEvents
        guard events.count <= limit else { throw .ownership(.batchTooLarge(count: events.count, limit: limit)) }
        let bound = boundInputs
        if let clash = events.first(where: { bound.contains($0.input) }) { throw .inputBoundToClip(clash.input) }
        var working = ledger
        var outputs: [MIDIRoutedOutput] = []
        for event in events {
            do throws(MIDIPerformanceRefusal) {
                try working.route(event, routing: routing, into: &outputs)
            } catch {
                throw .ledger(error)
            }
        }
        ledger = working
        return outputs
    }

    private func slot(of input: MIDIInputID) throws(MIDIClipHostRefusal) -> Int {
        guard let slot = clips.firstIndex(where: { $0.input.input == input }) else { throw .inputNotBound(input) }
        return slot
    }

    /// The slots of `inputs`, in list order, after the list checks (empty, oversized, repeated, unbound).
    private func slots(of inputs: [MIDIInputID]) throws(MIDIClipHostRefusal) -> [Int] {
        guard !inputs.isEmpty else { throw .noInputs }
        guard inputs.count <= Self.maximumClips else {
            throw .inputListTooLarge(count: inputs.count, limit: Self.maximumClips)
        }
        var seen: Set<MIDIInputID> = []
        for id in inputs where !seen.insert(id).inserted { throw .inputListedTwice(id) }
        var slots: [Int] = []
        for id in inputs { slots.append(try slot(of: id)) }
        return slots
    }

    private func route(
        _ batch: [MIDIClipSourcedEvent], ledger: inout MIDINoteLedger
    ) throws(MIDIClipHostRefusal) -> MIDIClipOwnershipReport {
        do throws(MIDIClipOwnershipRefusal) {
            return try MIDIClipOwnershipReport.route(batch, ledger: &ledger)
        } catch {
            throw .ownership(error)
        }
    }

    private mutating func route(
        _ events: [MIDIClipEvent], slot: Int
    ) throws(MIDIClipHostRefusal) -> MIDIClipOwnershipReport {
        let clip = clips[slot].input
        var working = ledger
        let report = try route(events.map { MIDIClipSourcedEvent(event: $0, clip: clip) }, ledger: &working)
        ledger = working
        return report
    }
}
