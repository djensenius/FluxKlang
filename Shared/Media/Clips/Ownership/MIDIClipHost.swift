//
//  MIDIClipHost.swift
//  FluxKlang
//
//  Clips playing as performance inputs, sharing one note ledger (#112 CL9). The host OWNS the ledger and every
//  clip's scheduler and hands out no playback value: each operation names a clip by its `MIDIInputID`. That makes
//  the identity exclusive (one clip per input, no copy of a clip to stop twice or against another ledger) and the
//  ledger binding fixed (a clip is only ever routed into this host's ledger). A clip's stop is its scheduler's own
//  Note Offs routed under the clip's input: never a panic, an input loss or a route loss, which are broader than the
//  clip's ownership. Another input's notes (a drone) therefore survive every clip operation.
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
    /// The clip's scheduler refused.
    case clip(MIDIClipRefusal)
    /// The batch was refused before the ledger was touched.
    case ownership(MIDIClipOwnershipRefusal)
    /// The ledger refused a pass-through event.
    case ledger(MIDIPerformanceRefusal)
}

/// One note ledger plus the clips (at most `maximumClips`, one per input) that play into it.
struct MIDIClipHost: Equatable, Sendable {
    /// The most clips one host binds.
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

    /// Renders the clip of `input` over `[start, end)` and routes its events into the ledger. A scheduler refusal
    /// leaves the clip and the ledger unchanged; a per-event ledger refusal is reported without aborting the rest.
    mutating func render(
        input: MIDIInputID, from start: Int64, to end: Int64, clock: MusicalClockMap, current: MIDIClipGenerations
    ) throws(MIDIClipHostRefusal) -> MIDIClipOwnershipReport {
        let slot = try slot(of: input)
        var scheduler = clips[slot].scheduler
        let events: [MIDIClipEvent]
        do throws(MIDIClipRefusal) {
            events = try scheduler.render(from: start, to: end, clock: clock, current: current)
        } catch {
            throw .clip(error)
        }
        let report = try route(events, slot: slot)
        clips[slot].scheduler = scheduler
        return report
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

    private mutating func route(
        _ events: [MIDIClipEvent], slot: Int
    ) throws(MIDIClipHostRefusal) -> MIDIClipOwnershipReport {
        do throws(MIDIClipOwnershipRefusal) {
            return try MIDIClipOwnershipReport.route(events, through: clips[slot].input, ledger: &ledger)
        } catch {
            throw .ownership(error)
        }
    }
}
