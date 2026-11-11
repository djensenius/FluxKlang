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
//  already played; the next nonempty render leaves them out by tick before the
//  event limit is checked (the placement floor). The sounding set carries over
//  unchanged: no note is played again, and each sounding note's Note Off plays
//  at its tick's frame on the new map.
//

extension MIDIClipScheduler {
    /// The checks of `rebind` in order: a cursor, the cursor frame, the transport generation, the clock against
    /// `current`, the transport loop iteration, then the kept tick and its new cursor frame. Pure; `rebind`
    /// applies the result.
    func rebindTarget(clock: MusicalClockMap, current: ClockGenerationSnapshot,
                      atFrame frame: Int64) throws(MIDIClipRefusal) -> (ticks: Int64, frame: Int64) {
        guard let cursor, let binding, let cursorTicks else { throw .rebindWithoutRender }
        guard frame == cursor else { throw .rebindCursorMismatch(expected: cursor, frame: frame) }
        guard current.transport == binding.transport else {
            throw .transportChangedRequiresStop(expected: binding.transport, got: current.transport)
        }
        try MIDIClipPlacement.validate(clock, current: current)
        try Self.checkLoopIteration(of: clock, bound: loopIteration)
        // The old cursor frame is kept when the new map puts the same tick boundary there, so a revision that
        // leaves the cursor tick in place needs no jump in the caller's frames. A tick the new map cannot
        // represent at the old frame is not that boundary.
        if (try? MIDIClipPlacement.firstTick(atOrAfterFrame: cursor, clock: clock)) == cursorTicks {
            return (cursorTicks, cursor)
        }
        do {
            return (cursorTicks, try clock.frame(atTicks: cursorTicks))
        } catch {
            throw .clock(error)
        }
    }

    /// A loop wrap re-anchors the transport at the loop start and bumps no generation (media contract §5.1,
    /// §5.5), so a clock whose loop iteration differs from the bound one is refused until `stop()`.
    static func checkLoopIteration(of clock: MusicalClockMap, bound: UInt32?) throws(MIDIClipRefusal) {
        if let bound, clock.musical.loopIteration != bound {
            throw .loopWrapRequiresStop(expected: bound, got: clock.musical.loopIteration)
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
