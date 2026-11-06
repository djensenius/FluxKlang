//
//  MIDIClipScheduler+Rebind.swift
//  FluxKlang
//
//  Tick-based continuity across a clock re-anchor (#112 CL3). The scheduler's
//  position is the first timeline tick not yet passed (`cursorTicks`): every
//  tick below it has a frame before the cursor on the map it was rendered on.
//  A rebind keeps the cursor frame if the new map puts that same boundary
//  there (every earlier tick before it, the cursor tick at or after it).
//  Otherwise the cursor moves to the cursor tick's frame on the new map, the
//  earliest frame of any tick at or after it, so nothing still to play is
//  skipped. Ticks below it that the new map rounds onto that same frame were
//  already played, and the next nonempty render skips them by tick. The
//  sounding set carries over unchanged: no note is played again, and each
//  sounding note's Note Off plays at its tick's frame on the new map.
//

extension MIDIClipScheduler {
    /// The checks of `rebind` in order: a cursor, the cursor frame, the transport generation, the clock against
    /// `current`, then the kept tick and its new cursor frame. Pure; `rebind` applies the result.
    func rebindTarget(clock: MusicalClockMap, current: MIDIClipGenerations,
                      atFrame frame: Int64) throws(MIDIClipRefusal) -> (ticks: Int64, frame: Int64) {
        guard let cursor, let binding, let cursorTicks else { throw .rebindWithoutRender }
        guard frame == cursor else { throw .rebindCursorMismatch(expected: cursor, frame: frame) }
        guard current.transport == binding.transport else {
            throw .transportChangedRequiresStop(expected: binding.transport, got: current.transport)
        }
        try MIDIClipPlacement.validate(clock, current: current)
        do {
            let tickFrame = try clock.frame(atTicks: cursorTicks)
            // The old cursor frame is kept when the new map puts the same tick boundary there, so a revision that
            // leaves the cursor tick in place needs no jump in the caller's frames. A tick the new map cannot
            // represent at the old frame is not that boundary.
            let kept = (try? MIDIClipPlacement.firstTick(atOrAfterFrame: cursor, clock: clock)) == cursorTicks
            return (cursorTicks, kept ? cursor : tickFrame)
        } catch {
            throw .clock(error)
        }
    }

    /// The first tick not yet passed after rendering `[start, end)`: an empty render after the first keeps
    /// `previous` (which a rebind may have set above the new map's tick at the cursor); otherwise it is the first
    /// tick whose frame is at or after `end`.
    static func reachedTicks(previous: Int64?, from start: Int64, to end: Int64,
                             clock: MusicalClockMap) throws(MIDIClipRefusal) -> Int64 {
        if let previous, end == start { return previous }
        do {
            return try MIDIClipPlacement.firstTick(atOrAfterFrame: end, clock: clock)
        } catch {
            throw .clock(error)
        }
    }
}

extension MIDIClipPlacement {
    /// The timeline tick of an event this placement scheduled, from its pass, item and kind: a Note Off sits at the
    /// note's end, cut at the pass end, and pass k ≥ 1 is shifted by k loop lengths.
    func timelineTicks(of event: MIDIClipEvent) -> Int128 {
        let passEnd = loop?.endTicks ?? clip.lengthTicks
        let clipTicks: Int64
        switch clip.items[event.item] {
        case .note(let note):
            if case .noteOff = event.message {
                clipTicks = min(note.endTicks, passEnd)
            } else {
                clipTicks = note.startTicks
            }
        case .event(let ticks, _):
            clipTicks = ticks
        }
        let loopLength = loop.map { $0.endTicks - $0.startTicks } ?? 0
        return Int128(startTicks) + Int128(event.pass) * Int128(loopLength) + Int128(clipTicks)
    }
}
