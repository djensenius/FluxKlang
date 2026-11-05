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
//  (`clockRevisionChanged`), sounding notes or not. The caller must `stop()` at
//  a clock-map change or a transport loop wrap, then render on the new map.
//  Carrying playback across a re-anchor (a tick-based position) is a follow-up.
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
    /// The generations of the first render since creation or `stop()`; later renders must match them.
    private(set) var binding: MIDIClipGenerations?
    private var sounding: Set<Instance> = []

    init(placement: MIDIClipPlacement) {
        self.placement = placement
    }

    /// The number of notes this scheduler started and has not released.
    var soundingCount: Int { sounding.count }

    /// Plays the window `[start, end)`. The first render since creation or `stop()` may start anywhere and binds
    /// the scheduler to `current`; a Note Off whose note started before it is not played, as the clip never
    /// started that note. A refusal leaves the scheduler unchanged.
    mutating func render(from start: Int64, to end: Int64, clock: MusicalClockMap,
                         current: MIDIClipGenerations) throws(MIDIClipRefusal) -> [MIDIClipEvent] {
        if let cursor, cursor != start { throw .nonContiguousWindow(expected: cursor, start: start) }
        try MIDIClipPlacement.validate(clock, current: current)
        if let binding, binding != current { throw .clockRevisionChanged(expected: binding, got: current) }
        let scheduled = try placement.events(from: start, to: end, clock: clock, current: current)
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
        }
        guard let cursor else { return [] }
        return sounding.sorted { ($0.pass, $0.item) < ($1.pass, $1.item) }.compactMap { instance in
            placement.clip.noteOff(item: instance.item).map {
                MIDIClipEvent(frame: cursor, pass: instance.pass, item: instance.item, message: $0)
            }
        }
    }
}
