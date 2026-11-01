import Foundation

/// Ephemeral per-search lookup, never retained by a timeline or pin.
/// Populate pins first, records in observation order, then current state to preserve precedence.
struct MusicalProjectionIndex: Sendable {
    private var anchors: [Int128: ClockAnchor] = [:]
    private(set) var originalTicks: [Int128: Int64] = [:]
    private(set) var retainedPasses: Set<Int128> = []

    mutating func includeReservation(_ occurrence: MusicalOccurrence, originalTicks: Int64,
                                     pass: Int128, anchor: ClockAnchor?) {
        if self.originalTicks[occurrence.pass] == nil { self.originalTicks[occurrence.pass] = originalTicks }
        if let anchor {
            if anchors[pass] == nil { anchors[pass] = anchor }
            retainedPasses.insert(pass)
        }
    }

    mutating func includeRecord(_ clock: MusicalClockMap, running: Bool) {
        let pass = Int128(clock.musical.loopIteration)
        retainedPasses.insert(pass)
        if running { anchors[pass] = clock.anchor }
    }

    mutating func includeCurrent(_ clock: MusicalClockMap, running: Bool) {
        let pass = Int128(clock.musical.loopIteration)
        retainedPasses.insert(pass)
        if running { anchors[pass] = clock.anchor }
    }

    func anchor(for pass: Int128) -> ClockAnchor? { anchors[pass] }

    func containsOriginalPass(_ pass: Int128) -> Bool {
        retainedPasses.contains(pass) || originalTicks[pass] != nil
    }
}

extension MusicalTimeline {
    func projectedPrevious(pass initial: Int128, at frame: MusicalFrame, grid: Int64, heldTicks: Int64?,
                           using index: MusicalProjectionIndex)
        throws -> (occurrence: MusicalOccurrence, units: Int128)? {
        let (passes, missing) = previousPasses(through: initial, grid: grid, using: index)
        var best: (occurrence: MusicalOccurrence, units: Int128)?
        var unavailable = false
        // Each available pass supplies at most one inverse and an independently qualified end.
        // Descending retained keys settle remaining ties without walking numeric passes or grid ticks.
        for pass in passes.sorted(by: >) {
            let candidates = try previousCandidates(pass: pass, at: frame, grid: grid,
                ceiling: pass == initial ? heldTicks ?? Int64.max : Int64.max, using: index)
            unavailable = unavailable || candidates.unavailable
            for occurrence in candidates.occurrences {
                let units: Int128
                do {
                    units = try projectionUnits(for: occurrence, using: index)
                } catch MusicalTimingError.historyUnavailable { unavailable = true; continue }
                guard MusicalFrame(units: units) <= frame else { continue }
                let isEnd = currentLoop?.endTicks == occurrence.ticks
                if let current = best, units < current.units
                    || (units == current.units && (isEnd || currentLoop?.endTicks != current.occurrence.ticks)) {
                    continue // Equal exact frames prefer an ordinary interior over a loop end.
                }
                best = (occurrence, units)
            }
        }
        if let missing {
            // A retained exact-frame winner is safe only if no missing pass can beat its remaining tie ranks.
            guard let best, let loop = currentLoop, MusicalFrame(units: best.units) == frame,
                  best.occurrence.pass > missing,
                  best.occurrence.ticks < loop.endTicks || loop.endTicks - grid < loop.startTicks else {
                throw MusicalTimingError.historyUnavailable
            }
        }
        if let best { return best }
        // Missing earlier context cannot invent a candidate, nor invalidate an independently usable one.
        if unavailable { throw MusicalTimingError.historyUnavailable }
        return nil
    }

    private func previousPasses(through initial: Int128, grid: Int64, using index: MusicalProjectionIndex)
        -> (Set<Int128>, Int128?) {
        var passes: Set<Int128> = [initial]
        guard let loop = currentLoop else { return (passes, nil) }
        guard Int128(loop.endTicks) / Int128(grid) * Int128(grid) >= Int128(loop.startTicks) else { return ([], nil) }
        passes.formUnion(index.retainedPasses)
        let anchors = passes.filter { $0 <= initial }.sorted()
        // Tick-only summaries must not close gaps between retained full anchors.
        let missing = zip(anchors, anchors.dropFirst()).filter { $0.1 - $0.0 > 1 }.last.map { $0.1 - 1 }
        passes.formUnion(index.originalTicks.keys)
        return (passes.filter { $0 <= initial }, missing)
    }

    private func previousCandidates(pass: Int128, at frame: MusicalFrame, grid: Int64, ceiling: Int64,
                                    using index: MusicalProjectionIndex)
        throws -> (occurrences: [MusicalOccurrence], unavailable: Bool) {
        var upper = min(Int128(ceiling), Int128(currentLoop?.endTicks ?? Int64.max))
        var candidates: [MusicalOccurrence] = []
        if let loop = currentLoop, upper == Int128(loop.endTicks), loop.endTicks % grid == 0 {
            candidates.append(MusicalOccurrence(pass: pass, ticks: loop.endTicks))
            upper -= 1
        }
        // A tick-only eligibility summary cannot supply an ordinary inverse.
        guard let anchor = index.anchor(for: pass)
            ?? (pass == Int128(currentClock.musical.loopIteration) ? currentClock.anchor : nil) else {
            return (candidates, true)
        }
        let clock = try MusicalTiming.reanchor(anchor, using: currentClock)
        let bounds = try MusicalTiming.gridBounds(at: frame, grid: grid, clock: clock)
        guard let previous = MusicalTiming.previousBoundary(pass: pass, ticks: min(bounds.previous, upper),
                                                            grid: grid, loop: currentLoop) else {
            return (candidates, false)
        }
        if previous.pass == pass { candidates.append(previous) }
        return (candidates, previous.pass < pass && !index.containsOriginalPass(previous.pass))
    }
}
