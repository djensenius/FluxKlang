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

    mutating func includeCurrent(_ clock: MusicalClockMap, running: Bool, initiallyHeld: Bool = false) {
        let pass = Int128(clock.musical.loopIteration)
        retainedPasses.insert(pass)
        if running || initiallyHeld { anchors[pass] = clock.anchor }
    }

    func anchor(for pass: Int128) -> ClockAnchor? { anchors[pass] }

    func containsOriginalPass(_ pass: Int128) -> Bool {
        retainedPasses.contains(pass) || originalTicks[pass] != nil
    }
}

extension MusicalTimeline {
    func projectedPrevious(pass initial: Int128, at frame: MusicalFrame, grid: Int64,
                           window: (milliseconds: Int, heldTicks: Int64?),
                           using index: MusicalProjectionIndex)
        throws -> (occurrence: MusicalOccurrence, units: Int128)? {
        let passes = previousPasses(through: initial, grid: grid, using: index)
        let frames = previousFrameBounds(for: passes, using: index)
        let missing = try missingInverseBounds(in: passes, grid: grid, frames: frames,
                                               origin: (initial, window.heldTicks), using: index)
        var best: (occurrence: MusicalOccurrence, units: Int128)?
        var unresolved: [MusicalOccurrence] = []
        // Each available pass supplies at most one inverse and an independently qualified end.
        // Descending retained keys settle remaining ties without walking numeric passes or grid ticks.
        for pass in passes.sorted(by: >) {
            let ceiling = pass == initial ? window.heldTicks ?? Int64.max : Int64.max
            let candidates = try previousCandidates(pass: pass, at: frame, grid: grid,
                                                    ceiling: ceiling, using: index)
            for occurrence in candidates {
                let units: Int128
                do {
                    units = try projectionUnits(for: occurrence, using: index)
                } catch MusicalTimingError.historyUnavailable { unresolved.append(occurrence); continue }
                // A qualified exact-frame alias is not retroactive; strictly past ends keep the held tick cap.
                guard occurrence.ticks <= ceiling || MusicalFrame(units: units) == frame,
                      MusicalFrame(units: units) <= frame,
                      try MusicalTiming.isRetroactive(units, at: frame, milliseconds: window.milliseconds,
                                                       rate: sample.nominalRate) else { continue }
                let isEnd = currentLoop?.endTicks == occurrence.ticks
                if let current = best, units < current.units
                    || (units == current.units && (isEnd || currentLoop?.endTicks != current.occurrence.ticks)) {
                    continue // Equal exact frames prefer an ordinary interior over a loop end.
                }
                best = (occurrence, units)
            }
        }
        for gap in missing {
            guard try missingCannotWin(gap, against: best, at: frame, grid: grid,
                                       milliseconds: window.milliseconds) else {
                throw MusicalTimingError.historyUnavailable
            }
        }
        // Coverage of a pass's own end does not supply the anchor needed by its predecessor's end.
        for occurrence in unresolved {
            guard let dependency = try missingProjectionBound(for: occurrence, frames: frames, using: index) else {
                continue
            }
            guard try missingCannotWin(dependency, against: best, at: frame, grid: grid,
                                       milliseconds: window.milliseconds) else {
                throw MusicalTimingError.historyUnavailable
            }
        }
        return best
    }

    private func previousPasses(through initial: Int128, grid: Int64, using index: MusicalProjectionIndex)
        -> Set<Int128> {
        var passes: Set<Int128> = [initial]
        guard let loop = currentLoop else { return passes }
        let last = loop.endTicks / grid * grid
        guard last >= loop.startTicks else { return [] }
        passes.formUnion(index.retainedPasses)
        passes.formUnion(index.originalTicks.keys)
        return passes.filter { $0 <= initial }
    }

    private func previousFrameBounds(for passes: Set<Int128>, using index: MusicalProjectionIndex) -> [Int128: Int64] {
        let current = Int128(currentClock.musical.loopIteration)
        var keys = passes.union(index.retainedPasses).union([current])
        for pass in passes where pass < current { keys.insert(pass + 1) }
        var frames: [Int128: Int64] = [:]
        // A held frame bounds earlier running frames, but never supplies an inverse/projection anchor.
        var upper: Int64? = isRunning ? nil : currentClock.anchor.sample.frame
        // Nearest later genuine anchor, never the end-only summary's proxy as an original anchor.
        for pass in keys.sorted(by: >) {
            if let anchor = previousAnchor(for: pass, using: index) { upper = anchor.sample.frame }
            if let upper { frames[pass] = upper }
        }
        return frames
    }

    private func missingInverseBounds(in passes: Set<Int128>, grid: Int64, frames: [Int128: Int64],
                                      origin: (pass: Int128, heldTicks: Int64?),
                                      using index: MusicalProjectionIndex)
        throws -> [(pass: Int128, upperUnits: Int128)] {
        guard let loop = currentLoop else { return [] }
        let last = loop.endTicks / grid * grid
        let interior = last == loop.endTicks ? last - grid : last
        let upperTick = last == loop.endTicks ? max(loop.startTicks, interior) : last
        let span = MusicalTiming.units(currentClock, from: 0, to: upperTick)
        var previous: Int128 = -1 // Include a discarded prefix, not just gaps between retained keys.
        var missing: [(pass: Int128, upperUnits: Int128)] = []
        for pass in passes.sorted() {
            let upper = pass == origin.pass ? min(interior, origin.heldTicks ?? interior) : interior
            let missingInterior = previousAnchor(for: pass, using: index) == nil && upper >= loop.startTicks
            if pass - previous > 1 || missingInterior {
                guard let frame = frames[pass] else { throw MusicalTimingError.historyUnavailable }
                let base = try MusicalTiming.multiply(Int128(frame), MusicalTiming.unitsPerFrame)
                if pass - previous > 1 {
                    missing.append((pass - 1, try MusicalTiming.add(base, span)))
                }
                if missingInterior {
                    // This pass's ticks bound only its own interior; end dependencies are checked separately.
                    let ticks = originalTicks(for: pass, using: index) ?? 0
                    missing.append((pass, try MusicalTiming.add(base,
                        MusicalTiming.units(currentClock, from: ticks, to: upper))))
                }
            }
            previous = pass
        }
        return missing
    }

    private func missingProjectionBound(for occurrence: MusicalOccurrence, frames: [Int128: Int64],
                                        using index: MusicalProjectionIndex)
        throws -> (pass: Int128, upperUnits: Int128)? {
        guard let loop = currentLoop, occurrence.ticks == loop.endTicks else {
            throw MusicalTimingError.historyUnavailable
        }
        let originalTicks = self.originalTicks(for: occurrence.pass, using: index)
        guard let originalTicks else {
            // Unknown eligibility: an unqualified end is no later than its anchor; an alias uses startTicks.
            guard let frame = frames[occurrence.pass] else { throw MusicalTimingError.historyUnavailable }
            return try (occurrence.pass, MusicalTiming.add(
                MusicalTiming.multiply(Int128(frame), MusicalTiming.unitsPerFrame),
                MusicalTiming.units(currentClock, from: 0, to: loop.startTicks)))
        }
        let pass = try MusicalTiming.projectionPass(occurrence, loop: loop, anchorTicks: originalTicks)
        // A held clock past the end cannot supply a future alias qualified by an older running anchor.
        // That candidate is known to be unprojectable, not missing earlier provenance.
        if pass > Int128(currentClock.musical.loopIteration), currentClock.musical.ticks > loop.endTicks {
            return nil
        }
        guard let frame = frames[pass] else { throw MusicalTimingError.historyUnavailable }
        let ticks = pass == occurrence.pass ? occurrence.ticks : loop.startTicks
        let anchorTicks = self.originalTicks(for: pass, using: index) ?? 0
        return try (occurrence.pass, MusicalTiming.add(
            MusicalTiming.multiply(Int128(frame), MusicalTiming.unitsPerFrame),
            MusicalTiming.units(currentClock, from: anchorTicks, to: ticks)))
    }

    private func previousAnchor(for pass: Int128, using index: MusicalProjectionIndex) -> ClockAnchor? {
        index.anchor(for: pass)
    }

    func qualifiedEnd(pass: Int128, grid: Int64, floor: Int64? = nil,
                      using index: MusicalProjectionIndex) -> MusicalOccurrence? {
        guard let loop = currentLoop, loop.endTicks % grid == 0, floor ?? 0 <= loop.endTicks else { return nil }
        let future = pass > Int128(currentClock.musical.loopIteration) && currentClock.musical.ticks <= loop.endTicks
        guard let ticks = originalTicks(for: pass, using: index) ?? (future ? loop.startTicks : nil),
              ticks <= loop.endTicks else { return nil }
        return MusicalOccurrence(pass: pass, ticks: loop.endTicks)
    }

    private func missingCannotWin(_ missing: (pass: Int128, upperUnits: Int128),
                                  against best: (occurrence: MusicalOccurrence, units: Int128)?,
                                  at frame: MusicalFrame, grid: Int64, milliseconds: Int) throws -> Bool {
        // An exact-origin or upper-bound winner must also beat every missing pass's remaining tie ranks.
        if let best, let loop = currentLoop,
           MusicalFrame(units: best.units) == frame || best.units == missing.upperUnits,
           best.occurrence.pass > missing.pass,
           best.occurrence.ticks < loop.endTicks || loop.endTicks - grid < loop.startTicks { return true }
        if let best, missing.upperUnits < best.units { return true }
        guard MusicalFrame(units: missing.upperUnits) <= frame else { return false }
        return try !MusicalTiming.isRetroactive(missing.upperUnits, at: frame, milliseconds: milliseconds,
                                                rate: sample.nominalRate)
    }

    private func previousCandidates(pass: Int128, at frame: MusicalFrame, grid: Int64, ceiling: Int64,
                                    using index: MusicalProjectionIndex)
        throws -> [MusicalOccurrence] {
        var upper = min(Int128(ceiling), Int128(currentLoop?.endTicks ?? Int64.max))
        var candidates: [MusicalOccurrence] = []
        if let loop = currentLoop, loop.endTicks % grid == 0 {
            if ceiling >= loop.endTicks || qualifiedEnd(pass: pass, grid: grid, using: index) != nil {
                candidates.append(MusicalOccurrence(pass: pass, ticks: loop.endTicks))
            }
            upper = min(upper, Int128(loop.endTicks) - 1)
        }
        // A tick-only eligibility summary cannot supply an ordinary inverse.
        guard let anchor = previousAnchor(for: pass, using: index) else { return candidates }
        let clock = try MusicalTiming.reanchor(anchor, using: currentClock)
        let bounds = try MusicalTiming.gridBounds(at: frame, grid: grid, clock: clock)
        guard let previous = MusicalTiming.previousBoundary(pass: pass, ticks: min(bounds.previous, upper),
                                                            grid: grid, loop: currentLoop) else {
            return candidates
        }
        if previous.pass == pass { candidates.append(previous) }
        return candidates
    }
}
