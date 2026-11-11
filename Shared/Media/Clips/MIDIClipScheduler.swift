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
//  (`clockRevisionChanged`), sounding notes or not. It also records the bound
//  clock's transport loop iteration and refuses a clock with another one
//  (`loopWrapRequiresStop`): a loop wrap bumps no generation (media contract
//  §5.1, §5.5). The caller must `stop()` at a locate or a transport loop wrap;
//  `rebind` refuses both. At a tempo map revision with the same transport, the
//  caller may `rebind` (CL3, MIDIClipScheduler+Rebind.swift): the cursor is kept
//  as a tick and re-expressed on the new map, and sounding notes carry over.
//  Under the media contract a sample-clock bump (a device restart) always bumps
//  the transport too, so it is refused with `transportChangedRequiresStop`; the
//  same-transport sample re-anchor path is defensive.
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
    private(set) var binding: ClockGenerationSnapshot?
    /// The transport loop iteration of the bound clock; a clock with another one is a loop wrap. Cleared by `stop()`.
    private(set) var loopIteration: UInt32?
    /// The first timeline tick not yet passed: every tick below it lies before the cursor. Kept across `rebind`.
    private(set) var cursorTicks: Int64?
    /// Set by `rebind`: ticks below it that the new map puts on the cursor frame were already played, so the next
    /// nonempty render leaves them out before the event limit. Cleared by that render or `stop()`.
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
    /// frame were already played and are left out (they do not count toward the event limit). A clock with another
    /// transport loop iteration than the bound one is refused (`loopWrapRequiresStop`). Even an empty window can
    /// be refused with `.clock(.overflow)` when its end tick is not representable, at frames where any nonempty
    /// render would be refused too. A refusal leaves the scheduler unchanged.
    mutating func render(from start: Int64, to end: Int64, clock: MusicalClockMap,
                         current: ClockGenerationSnapshot) throws(MIDIClipRefusal) -> [MIDIClipEvent] {
        if let cursor, cursor != start { throw .nonContiguousWindow(expected: cursor, start: start) }
        try MIDIClipPlacement.validate(clock, current: current)
        if let binding, binding != current { throw .clockRevisionChanged(expected: binding, got: current) }
        try Self.checkLoopIteration(of: clock, bound: loopIteration)
        let scheduled = try placement.events(from: start, to: end, clock: clock, current: current, floor: replayFloor)
        let reached = try Self.reachedTicks(previous: cursorTicks, from: start, to: end, clock: clock)
        var next = sounding
        var played: [MIDIClipEvent] = []
        for event in scheduled {
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
        loopIteration = clock.musical.loopIteration
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
            loopIteration = nil
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
    /// frame of `cursorTicks`. Every note still sounding releases at its Note Off tick's frame on the new map.
    /// Allowed only at the cursor after a render, with the transport generation and loop iteration unchanged (a
    /// tempo map revision; a same-transport sample re-anchor is accepted defensively, though under the media
    /// contract a sample-clock bump always bumps the transport). A locate is refused with
    /// `transportChangedRequiresStop` and a loop wrap with `loopWrapRequiresStop`; the caller must `stop()`.
    /// A refusal leaves the scheduler unchanged.
    ///
    /// Caller policy: the next render must start at the updated `cursor`, not at `frame`. When the new map does
    /// not put the cursor tick boundary at `frame` (on the same sample clock, a revision anchored off that tick's
    /// frame), the cursor moves: backward means the next events come later than the frames already output (late),
    /// forward leaves a gap of frames with no events.
    mutating func rebind(clock: MusicalClockMap, current: ClockGenerationSnapshot,
                         atFrame frame: Int64) throws(MIDIClipRefusal) {
        let target = try rebindTarget(clock: clock, current: current, atFrame: frame)
        cursor = target.frame
        binding = current
        replayFloor = target.ticks
    }
}
