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
            if let previous = try projectedPrevious(pass: pass, at: frame, grid: grid, heldTicks: held, using: index) {
                if MusicalFrame(units: previous.units) == frame { return previous.occurrence }
                if try MusicalTiming.isRetroactive(previous.units, at: frame, milliseconds: retroactiveMs,
                                                    rate: sample.nominalRate) { return previous.occurrence }
            }
            return try projectedNext(pass: pass, at: frame, grid: grid, minimumTicks: forwardFloor(for: origin),
                                     using: index)
        }
    }

    private func forwardFloor(for origin: MusicalOrigin) throws -> Int64? {
        guard origin.isRunning else { return origin.clock.musical.ticks }
        guard origin.clock.musical.loopIteration == 0, let loop = currentLoop else { return nil }
        // Initial tick membership is eligibility only; the first anchor never replaces a discarded projection anchor.
        if let ticks = firstMusicalAnchor.musical?.ticks, loop.admits(ticks: ticks) { return loop.startTicks }
        let clock = try MusicalTiming.reanchor(origin.clock.anchor, using: currentClock)
        return try loopContains(origin.exactFrame, from: clock, loop: loop) ? loop.startTicks : nil
    }

    private func loopContains(_ frame: MusicalFrame, from clock: MusicalClockMap, loop: LoopRange) throws -> Bool {
        let base = try MusicalTiming.multiply(Int128(clock.anchor.sample.frame), MusicalTiming.unitsPerFrame)
        let start = try MusicalTiming.add(base,
            MusicalTiming.units(clock, from: clock.musical.ticks, to: loop.startTicks))
        let end = try MusicalTiming.add(base, MusicalTiming.units(clock, from: clock.musical.ticks, to: loop.endTicks))
        if frame >= MusicalFrame(units: start), frame <= MusicalFrame(units: end) { return true }
        guard clock.musical.ticks <= loop.endTicks else { return false }
        let wrap = try MusicalTiming.wrapFrame(clock, loop: loop)
        guard frame >= MusicalFrame(integer: wrap) else { return false }
        let span = MusicalTiming.units(clock, from: loop.startTicks, to: loop.endTicks)
        let period = MusicalTiming.rounded(span)
        guard period > 0 else {
            guard frame == MusicalFrame(integer: wrap) else { throw MusicalTimingError.nonAdvancingLoop }
            return true
        }
        // Classify only the rounded-period phase; never construct or change the authenticated origin's pass.
        let elapsed = try MusicalTiming.add(frame.whole, -wrap)
        let phaseStart = try MusicalTiming.add(frame.whole, -(elapsed % period))
        return try frame <= MusicalFrame(units: MusicalTiming.add(
            MusicalTiming.multiply(phaseStart, MusicalTiming.unitsPerFrame), span))
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
            let anchor: (ticks: Int64, units: Int128)
            let candidates: [MusicalOccurrence]
            do {
                anchor = try forwardAnchor(for: pass, using: index)
                candidates = try forwardCandidates(pass: pass, at: frame, grid: grid, anchor: anchor,
                                                    floor: pass == initial ? minimumTicks : nil)
            } catch let error as MusicalTimingError {
                failure = error
                if error == .historyUnavailable, pass <= current {
                    unresolved = earlier(unresolved, MusicalOccurrence(pass: pass, ticks: 0))
                }
                continue
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
        if let anchor = index.anchor(for: pass) ?? (pass == current ? currentClock.anchor : nil) {
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
        var candidates: [MusicalOccurrence] = []
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
            if eligible, loop.endTicks % grid == 0, floor ?? 0 <= loop.endTicks {
                candidates.append(MusicalOccurrence(pass: pass, ticks: loop.endTicks))
            }
        } else if let floor {
            ticks = max(ticks, ExactMath.ceilDiv(Int128(floor), Int128(grid)) * Int128(grid))
        }
        candidates.append(try MusicalOccurrence(pass: nextPass, ticks: MusicalTiming.narrow(ticks)))
        return candidates
    }

    private func forwardUnits(_ occurrence: MusicalOccurrence, pass: Int128,
                              anchor: (ticks: Int64, units: Int128), using index: MusicalProjectionIndex)
        throws -> Int128 {
        if currentLoop?.admits(ticks: occurrence.ticks) == false, occurrence.pass == pass {
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
