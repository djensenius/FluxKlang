import Foundation

extension MusicalTimeline {
    /// Called only after reserve authenticates the origin. Returning an occurrence grants no pin or authority.
    func select(_ target: MusicalTarget, origin: MusicalOrigin, retroactiveMs: Int,
                using index: MusicalProjectionIndex) throws -> MusicalOccurrence {
        let pass = Int128(origin.clock.musical.loopIteration)
        switch target {
        case .absolute(let ticks):
            guard ticks >= 0 else { throw MusicalTimingError.invalidTarget }
            return MusicalOccurrence(pass: pass, ticks: ticks) // prepare retains the active-loop admission check.
        case .grid(let grid):
            guard grid > 0 else { throw MusicalTimingError.invalidTarget }
            let frame = origin.isRunning ? origin.exactFrame : MusicalFrame(origin.clock.anchor.sample.frame)
            let held = origin.isRunning ? nil : origin.clock.musical.ticks
            if let previous = try projectedPrevious(pass: pass, at: frame, grid: grid,
                                                   window: (retroactiveMs, held), using: index) {
                if MusicalFrame(units: previous.units) == frame {
                    return try exactHeldWinner(previous.occurrence, at: frame, grid: grid,
                                               origin: (pass, held), using: index)
                }
                if try MusicalTiming.isRetroactive(previous.units, at: frame, milliseconds: retroactiveMs,
                                                    rate: sample.nominalRate) { return previous.occurrence }
            }
            return try projectedNext(pass: pass, at: frame, grid: grid, minimumTicks: forwardFloor(for: origin),
                                     using: index)
        }
    }

    private func exactHeldWinner(_ previous: MusicalOccurrence, at frame: MusicalFrame, grid: Int64,
                                 origin: (pass: Int128, ceiling: Int64?), using index: MusicalProjectionIndex)
        throws -> MusicalOccurrence {
        guard let ceiling = origin.ceiling, previous.pass == origin.pass, previous.ticks > ceiling,
              let loop = currentLoop, previous.ticks == loop.endTicks else { return previous }
        // The capped predecessor already proves candidates at/below held ticks. Only the exact-forward
        // ordinary competitors above that ceiling remain; an empty domain needs no inverse anchor.
        let lower = max(Int128(origin.pass > 0 ? loop.startTicks : 0), Int128(ceiling) + 1)
        let first = ExactMath.ceilDiv(lower, Int128(grid)) * Int128(grid)
        guard first < Int128(loop.endTicks) else { return previous }
        let anchor = try forwardAnchor(for: origin.pass, using: index)
        let candidates = try forwardCandidates(pass: origin.pass, at: frame, grid: grid,
                                               anchor: anchor, floor: MusicalTiming.narrow(first))
        for occurrence in candidates where occurrence.pass == origin.pass && occurrence.ticks < loop.endTicks {
            let units = try forwardUnits(occurrence, pass: origin.pass, anchor: anchor, using: index)
            if MusicalFrame(units: units) == frame { return occurrence }
        }
        return previous
    }

    private func forwardFloor(for origin: MusicalOrigin) throws -> Int64? {
        guard origin.isRunning else { return origin.clock.musical.ticks }
        guard origin.clock.musical.loopIteration == 0, let loop = currentLoop else { return nil }
        // Initial tick membership is eligibility only; the first anchor never replaces a discarded projection anchor.
        if let ticks = firstMusicalAnchor.musical?.ticks, loop.admits(ticks: ticks) { return loop.startTicks }
        let clock = try MusicalTiming.reanchor(origin.clock.anchor, using: currentClock)
        return try reachesLoopStart(origin.exactFrame, from: clock, loop: loop) ? loop.startTicks : nil
    }

    private func reachesLoopStart(_ frame: MusicalFrame, from clock: MusicalClockMap, loop: LoopRange) throws -> Bool {
        guard clock.musical.ticks <= loop.endTicks else { return false }
        let base = try MusicalTiming.multiply(Int128(clock.anchor.sample.frame), MusicalTiming.unitsPerFrame)
        let start = try MusicalTiming.add(base,
            MusicalTiming.units(clock, from: clock.musical.ticks, to: loop.startTicks))
        // The covered origin stays in its recorded pass even beyond the exact end or a virtual wrap.
        return frame >= MusicalFrame(units: start)
    }

    /// Exact mirror of the predecessor search. No hypothetical pass becomes origin coverage.
    private func projectedNext(pass initial: Int128, at frame: MusicalFrame, grid: Int64, minimumTicks: Int64?,
                               using index: MusicalProjectionIndex)
        throws -> MusicalOccurrence {
        let current = Int128(currentClock.musical.loopIteration)
        let (passes, gap) = try forwardPasses(from: initial, using: index)
        var unresolved = gap
        var best: (occurrence: MusicalOccurrence, units: Int128)?
        var failure: MusicalTimingError = currentLoop == nil ? .overflow : .outsideLoop
        for pass in passes.sorted() {
            let floor = pass == initial ? minimumTicks : nil
            var anchor: (ticks: Int64, units: Int128)?
            var candidates = qualifiedEnd(pass: pass, grid: grid, floor: floor, using: index).map { [$0] } ?? []
            do {
                let value = try forwardAnchor(for: pass, using: index)
                anchor = value
                candidates += try forwardCandidates(pass: pass, at: frame, grid: grid, anchor: value, floor: floor)
            } catch let error as MusicalTimingError {
                failure = error
                if error == .historyUnavailable, pass <= current,
                   try needsForwardInverse(pass: pass, at: frame, grid: grid, floor: floor, using: index) {
                    unresolved = earlier(unresolved, MusicalOccurrence(pass: pass, ticks: 0))
                }
            }
            for occurrence in candidates {
                let units: Int128
                do {
                    units = try forwardUnits(occurrence, pass: pass, anchor: anchor, using: index)
                } catch let error as MusicalTimingError {
                    failure = error
                    if error == .historyUnavailable, occurrence.pass < current {
                        unresolved = earlier(unresolved, occurrence)
                    }
                    continue
                }
                if MusicalFrame(units: units) >= frame, precedes((occurrence, units), best) {
                    best = (occurrence, units)
                }
            }
        }
        if let unresolved {
            // Only an exact-frame winner preceding every unknown occurrence is provably unbeatable.
            guard let best, MusicalFrame(units: best.units) == frame,
                  isEarlier(best.occurrence, than: unresolved) else { throw MusicalTimingError.historyUnavailable }
        }
        guard let best else { throw failure }
        return best.occurrence
    }

    private func needsForwardInverse(pass: Int128, at frame: MusicalFrame, grid: Int64, floor: Int64?,
                                     using index: MusicalProjectionIndex) throws -> Bool {
        guard let loop = currentLoop,
              let end = qualifiedEnd(pass: pass, grid: grid, floor: floor, using: index) else { return true }
        // Pass zero's pre-loop candidates still need an inverse unless the authenticated floor excludes them.
        let lower = max(pass > 0 ? loop.startTicks : 0, floor ?? 0)
        guard ExactMath.ceilDiv(Int128(lower), Int128(grid)) * Int128(grid) < Int128(end.ticks) else { return false }
        guard !isRunning, pass == Int128(currentClock.musical.loopIteration),
              let ticks = originalTicks(for: pass, using: index) else { return true }
        // As in the predecessor, the held frame bounds the lost anchor without replacing it.
        // Every ordinary boundary is excluded only if the last one's exact upper bound precedes the origin.
        let upper = try MusicalTiming.add(
            MusicalTiming.multiply(Int128(currentClock.anchor.sample.frame), MusicalTiming.unitsPerFrame),
            MusicalTiming.units(currentClock, from: ticks, to: end.ticks - grid))
        return MusicalFrame(units: upper) >= frame
    }

    private func forwardPasses(from initial: Int128, using index: MusicalProjectionIndex)
        throws -> (Set<Int128>, MusicalOccurrence?) {
        let current = Int128(currentClock.musical.loopIteration)
        guard initial >= 0, initial <= current else { throw MusicalTimingError.historyUnavailable }
        guard currentLoop != nil else { return ([initial], nil) }
        let anchors = index.retainedPasses.union([initial, current]).filter { $0 >= initial }.sorted()
        let gap = zip(anchors, anchors.dropFirst()).first { $0.1 - $0.0 > 1 }
            .map { MusicalOccurrence(pass: $0.0 + 1, ticks: 0) }
        var passes = Set(anchors)
        // Expand exactly once over retained keys, not over the elapsed pass count.
        for pass in anchors {
            if pass > initial { passes.insert(pass - 1) }
            passes.insert(try MusicalTiming.add(pass, 1))
        }
        return (passes, gap)
    }

    private func forwardAnchor(for pass: Int128, using index: MusicalProjectionIndex)
        throws -> (ticks: Int64, units: Int128) {
        let current = Int128(currentClock.musical.loopIteration)
        if let anchor = index.anchor(for: pass) {
            let clock = try MusicalTiming.reanchor(anchor, using: currentClock)
            return try (clock.musical.ticks,
                        MusicalTiming.multiply(Int128(clock.anchor.sample.frame), MusicalTiming.unitsPerFrame))
        }
        guard pass > current, let loop = currentLoop else { throw MusicalTimingError.historyUnavailable }
        // Temporary inverse coordinates only: a tick-only pin summary never supplies an original anchor.
        return try (loop.startTicks,
                    MusicalTiming.projectedUnits(of: .init(pass: pass, ticks: loop.startTicks),
                                                  from: currentClock, loop: loop))
    }

    private func forwardCandidates(pass: Int128, at frame: MusicalFrame, grid: Int64,
                                   anchor: (ticks: Int64, units: Int128), floor: Int64?) throws -> [MusicalOccurrence] {
        var ticks = try MusicalTiming.gridBounds(at: frame, grid: grid, clock: currentClock,
                                                 projectionAnchor: anchor).forward
        var nextPass = pass
        if let loop = currentLoop {
            let first = ExactMath.ceilDiv(Int128(loop.startTicks), Int128(grid)) * Int128(grid)
            let end = ExactMath.ceilDiv(Int128(loop.endTicks), Int128(grid)) * Int128(grid)
            guard first <= Int128(loop.endTicks) else { throw MusicalTimingError.outsideLoop }
            if pass > 0 { ticks = max(ticks, first) }
            let eligible = anchor.ticks <= loop.endTicks
            if eligible { ticks = min(ticks, end) }
            if let floor { ticks = max(ticks, ExactMath.ceilDiv(Int128(floor), Int128(grid)) * Int128(grid)) }
            let endFrame = try MusicalFrame(units: MusicalTiming.add(anchor.units,
                MusicalTiming.units(currentClock, from: anchor.ticks, to: loop.endTicks)))
            if ticks > Int128(loop.endTicks), floor ?? 0 <= loop.endTicks,
               eligible || frame <= endFrame {
                nextPass = try MusicalTiming.add(pass, 1)
                ticks = first
            }
        } else if let floor {
            ticks = max(ticks, ExactMath.ceilDiv(Int128(floor), Int128(grid)) * Int128(grid))
        }
        return [try MusicalOccurrence(pass: nextPass, ticks: MusicalTiming.narrow(ticks))]
    }

    private func forwardUnits(_ occurrence: MusicalOccurrence, pass: Int128,
                              anchor: (ticks: Int64, units: Int128)?, using index: MusicalProjectionIndex)
        throws -> Int128 {
        if let anchor, currentLoop?.admits(ticks: occurrence.ticks) == false, occurrence.pass == pass {
            // Rank pre-loop/out-of-loop boundaries normally; prepare rejects them only if selected.
            return try MusicalTiming.add(anchor.units,
                MusicalTiming.units(currentClock, from: anchor.ticks, to: occurrence.ticks))
        }
        return try projectionUnits(for: occurrence, using: index)
    }

    private func precedes(_ candidate: (occurrence: MusicalOccurrence, units: Int128),
                          _ current: (occurrence: MusicalOccurrence, units: Int128)?) -> Bool {
        guard let current else { return true }
        return candidate.units < current.units
            || (candidate.units == current.units && isEarlier(candidate.occurrence, than: current.occurrence))
    }

    private func isEarlier(_ lhs: MusicalOccurrence, than rhs: MusicalOccurrence) -> Bool {
        lhs.pass < rhs.pass || (lhs.pass == rhs.pass && lhs.ticks < rhs.ticks)
    }

    private func earlier(_ first: MusicalOccurrence?, _ second: MusicalOccurrence) -> MusicalOccurrence {
        guard let first else { return second }
        return isEarlier(first, than: second) ? first : second
    }
}
