//
//  MIDIClipScheduler.swift
//  FluxKlang
//
//  Stateful playback of one placed MIDI clip (#112 CL1) over contiguous frame
//  windows. The scheduler tracks only its own sounding notes (one entry per
//  pass and note item): a Note Off is played only for a note it started, and
//  stop releases each sounding note exactly once. The clock map is passed in per
//  render and never cached. It does not use the performance note ledger.
//
//  Clock-map changes: frames are only comparable on one clock map, so the
//  scheduler binds to the generations of its first render after creation or
//  `stop()`, and refuses any render with other generations
//  (`clockRevisionChanged`), sounding notes or not. At a tempo map revision or a
//  sample-clock re-anchor with the same transport generation, the caller may
//  `rebind` (CL3, MIDIClipScheduler+Rebind.swift): the cursor is kept as a tick
//  and re-expressed on the new map, and sounding notes carry over. A transport
//  change (locate, loop wrap) is refused there too; the caller must `stop()`.
//  Joining a note already in progress at the first render is #107's job.
//
//  Restart: after `stop()` the scheduler may be restarted. Its next render
//  re-binds to that render's generations and may start at any frame, including
//  an earlier one; events already played are then played again, and avoiding
//  that replay is the caller's responsibility. A second `stop()` with no render
//  in between returns no events.
//

struct MIDIClipScheduler: Equatable, Sendable {
    private struct Instance: Hashable, Sendable {
        let pass: Int64
        let item: Int
    }

    private(set) var placement: MIDIClipPlacement
    /// The end of the last rendered window; the next render must start here.
    private(set) var cursor: Int64?
    /// The generations of the first render since creation or `stop()`, or of the last `rebind`; later renders
    /// must match them.
    private(set) var binding: MIDIClipGenerations?
    /// The first timeline tick not yet passed: every tick below it lies before the cursor. Kept across `rebind`.
    private(set) var cursorTicks: Int64?
    /// Set by `rebind`: ticks below it that the new map puts on the cursor frame were already played, so the next
    /// nonempty render skips them. Cleared by that render or `stop()`.
    private var replayFloor: Int64?
    private var sounding: Set<Instance> = []

    init(placement: MIDIClipPlacement) {
        self.placement = placement
    }

    /// The number of notes this scheduler started and has not released.
    var soundingCount: Int { sounding.count }

    /// Plays the window `[start, end)`. The first render since creation or `stop()` may start anywhere and binds
    /// the scheduler to `current`; a Note Off whose note started before it is not played, as the clip never
    /// started that note. After a `rebind`, events of ticks below `cursorTicks` that the new map puts on the cursor
    /// frame were already played and are skipped. A refusal leaves the scheduler unchanged.
    mutating func render(from start: Int64, to end: Int64, clock: MusicalClockMap,
                         current: MIDIClipGenerations) throws(MIDIClipRefusal) -> [MIDIClipEvent] {
        if let cursor, cursor != start { throw .nonContiguousWindow(expected: cursor, start: start) }
        try MIDIClipPlacement.validate(clock, current: current)
        if let binding, binding != current { throw .clockRevisionChanged(expected: binding, got: current) }
        let scheduled = try placement.events(from: start, to: end, clock: clock, current: current)
        let reached = try Self.reachedTicks(previous: cursorTicks, from: start, to: end, clock: clock)
        var next = sounding
        var played: [MIDIClipEvent] = []
        for event in scheduled {
            if let replayFloor, event.frame == start, placement.timelineTicks(of: event) < Int128(replayFloor) {
                continue
            }
            let instance = Instance(pass: event.pass, item: event.item)
            switch event.message {
            case .noteOff:
                guard next.remove(instance) != nil else { continue }
            case .noteOn:
                next.insert(instance)
            default:
                break
            }
            played.append(event)
        }
        sounding = next
        cursor = end
        binding = current
        cursorTicks = reached
        if end > start { replayFloor = nil }
        return played
    }

    /// Stops playback at the cursor: one Note Off per sounding note, by pass then authoring order. The scheduler
    /// then starts afresh: the next render may start anywhere and binds to its own generations. A second stop
    /// releases nothing. These Note Offs are complete: `MIDIClip.make` refuses hold controllers (CC 64, 66, 69)
    /// and channel mode messages, so no clip note can sound past its Note Off.
    mutating func stop() -> [MIDIClipEvent] {
        defer {
            sounding = []
            cursor = nil
            binding = nil
            cursorTicks = nil
            replayFloor = nil
        }
        guard let cursor else { return [] }
        return sounding.sorted { ($0.pass, $0.item) < ($1.pass, $1.item) }.compactMap { instance in
            placement.clip.noteOff(item: instance.item).map {
                MIDIClipEvent(frame: cursor, pass: instance.pass, item: instance.item, message: $0)
            }
        }
    }

    /// Re-expresses the cursor on `clock` for the generations `current`, keeping the sounding notes: the cursor
    /// stays where the new map puts the `cursorTicks` boundary at the old frame, else it moves to the new map's
    /// frame of `cursorTicks`; the next render starts at `cursor`. Every note still sounding releases at its Note
    /// Off tick's frame on the new map. Allowed only at the cursor after a render, with the transport generation
    /// unchanged (a tempo map revision or a sample-clock re-anchor). A locate or loop wrap is refused with
    /// `transportChangedRequiresStop`; the caller must `stop()`. A refusal leaves the scheduler unchanged.
    mutating func rebind(clock: MusicalClockMap, current: MIDIClipGenerations,
                         atFrame frame: Int64) throws(MIDIClipRefusal) {
        let target = try rebindTarget(clock: clock, current: current, atFrame: frame)
        cursor = target.frame
        binding = current
        replayFloor = target.ticks
    }
}
