import Foundation

/// Control-plane diagnostics, not additional v1 media outcome reasons.
enum MusicalTimingError: Error, Equatable, Sendable {
    case invalidBudget, invalidContext, invalidTransition, observationGap, timeRegressed, missingWrap
    case uncoveredOrigin, expiredOrigin, historyUnavailable, pinCapacity, invalidPin, pinsOutstanding
    case stopped, invalidTarget, outsideLoop, nonAdvancingLoop, overflow
}

enum MusicalTarget: Hashable, Sendable {
    case absolute(Int64)
    case grid(Int64)
}

/// An identity, not a committed frame or permission to schedule. Only a timeline can reserve a pin.
struct MusicalOccurrence: Hashable, Sendable {
    let pass: Int128
    let ticks: Int64
}

struct MusicalProjection: Hashable, Sendable {
    let occurrence: MusicalOccurrence
    let frame: Int64
    let musicalMap: Generation
    /// Projection beyond observed coverage does not manufacture historical observations.
    let assumesFuture: Bool
}

/// A split coordinate avoids multiplying a full-width frame by its host-timebase denominator.
struct MusicalFrame: Comparable, Sendable {
    let whole: Int128
    let numerator: Int128
    let denominator: Int128

    init(_ frame: Int64) { self.init(integer: Int128(frame)) }

    init(integer: Int128) {
        whole = integer
        numerator = 0
        denominator = 1
    }

    init(units: Int128) {
        denominator = MusicalTiming.unitsPerFrame
        whole = ExactMath.floorDiv(units, denominator)
        let remainder = units % denominator
        numerator = remainder < 0 ? remainder + denominator : remainder
    }

    init(host: HostStamp, through mapping: SampleClockMap) {
        let elapsed = (Int128(host.ticks) - Int128(mapping.anchor.host.ticks))
            * Int128(mapping.timebase.numer) * Int128(mapping.nominalRate)
        denominator = Int128(mapping.timebase.denom) * ExactMath.nanosPerSecond
        whole = Int128(mapping.anchor.sample.frame) + ExactMath.floorDiv(elapsed, denominator)
        let remainder = elapsed % denominator
        numerator = remainder < 0 ? remainder + denominator : remainder
    }

    // Both denominators are at most UInt32.max * 10^9; fraction products fit Int128.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.whole == rhs.whole && lhs.numerator * rhs.denominator == rhs.numerator * lhs.denominator
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.whole == rhs.whole ? lhs.numerator * rhs.denominator < rhs.numerator * lhs.denominator
            : lhs.whole < rhs.whole
    }

    func rounded() throws -> Int64 {
        try MusicalTiming.narrow(MusicalTiming.add(whole, numerator * 2 >= denominator ? 1 : 0))
    }
}

/// Exact, bounded control-plane calculations. Not an engine or render-thread implementation.
enum MusicalTiming {
    static let unitsPerFrame = Int128(MusicalTime.ticksPerQuarter) * ExactMath.microsPerSecond

    static func add(_ lhs: Int128, _ rhs: Int128) throws -> Int128 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw MusicalTimingError.overflow }
        return value
    }

    static func multiply(_ lhs: Int128, _ rhs: Int128) throws -> Int128 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw MusicalTimingError.overflow }
        return value
    }

    static func narrow(_ value: Int128) throws -> Int64 {
        guard let result = Int64(exactly: value) else { throw MusicalTimingError.overflow }
        return result
    }

    static func validate(_ clock: MusicalClockMap) throws {
        guard clock.musical.ticks >= 0 else { throw MusicalTimingError.invalidContext }
    }

    static func reanchor(_ anchor: ClockAnchor, using clock: MusicalClockMap) throws -> MusicalClockMap {
        try MusicalClockMap(anchor: anchor, map: clock.map, nominalRate: clock.nominalRate,
                            currentSample: clock.anchor.sample.generation, currentTransport: clock.musical.transport)
    }

    /// The integral is bounded by the existing Int64 tick and v1 tempo/rate domains (< 2^103 units).
    /// Potentially unbounded pass products use reporting-overflow operations separately.
    static func units(_ clock: MusicalClockMap, from start: Int64, to end: Int64) -> Int128 {
        if end < start { return -units(clock, from: end, to: start) }
        var result: Int128 = 0
        for (index, segment) in clock.map.segments.enumerated() {
            let lower = max(start, segment.atTicks)
            let upper = index + 1 < clock.map.segments.count ? min(end, clock.map.segments[index + 1].atTicks) : end
            if upper > lower {
                result += (Int128(upper) - Int128(lower))
                    * Int128(segment.microsPerQuarter) * Int128(clock.nominalRate)
            }
        }
        return result
    }

    static func rounded(_ units: Int128) -> Int128 {
        // Avoid doubling a potentially wide numerator.
        let whole = ExactMath.floorDiv(units, unitsPerFrame)
        let remainder = units % unitsPerFrame
        let positive = remainder < 0 ? remainder + unitsPerFrame : remainder
        return whole + (positive * 2 >= unitsPerFrame ? 1 : 0)
    }

    static func wrapFrame(_ clock: MusicalClockMap, loop: LoopRange) throws -> Int128 {
        try validate(clock)
        return try add(Int128(clock.anchor.sample.frame),
                       rounded(units(clock, from: clock.musical.ticks, to: loop.endTicks)))
    }

    /// The end alias is for projection only; it never mutates the stored identity.
    static func projectionPass(_ occurrence: MusicalOccurrence, loop: LoopRange?, anchorTicks: Int64) throws -> Int128 {
        guard occurrence.pass >= 0, occurrence.ticks >= 0 else { throw MusicalTimingError.invalidTarget }
        if let loop, loop.endTicks == occurrence.ticks, anchorTicks <= loop.endTicks {
            return try add(occurrence.pass, 1)
        }
        return occurrence.pass
    }

    static func frame(of occurrence: MusicalOccurrence, from clock: MusicalClockMap,
                      loop: LoopRange?) throws -> Int64 {
        try narrow(rounded(frameUnits(of: occurrence, from: clock, loop: loop)))
    }

    /// Keep a rational frame for window comparisons; rounding there would enlarge a retroactive window.
    static func frameUnits(of occurrence: MusicalOccurrence, from clock: MusicalClockMap,
                           loop: LoopRange?) throws -> Int128 {
        try validate(clock)
        guard loop?.admits(ticks: occurrence.ticks) ?? true else { throw MusicalTimingError.outsideLoop }
        guard occurrence.pass >= Int128(clock.musical.loopIteration) else {
            throw MusicalTimingError.historyUnavailable
        }
        let pass = try projectionPass(occurrence, loop: loop, anchorTicks: clock.musical.ticks)
        let ticks: Int64
        if let loop, pass != occurrence.pass { ticks = loop.startTicks } else { ticks = occurrence.ticks }
        return try projectedUnits(of: MusicalOccurrence(pass: pass, ticks: ticks), from: clock, loop: loop)
    }

    /// The caller has already qualified any end alias against its ORIGINAL pass anchor.
    static func projectedUnits(of occurrence: MusicalOccurrence, from clock: MusicalClockMap,
                               loop: LoopRange?) throws -> Int128 {
        try validate(clock)
        guard occurrence.ticks >= 0 else { throw MusicalTimingError.invalidTarget }
        guard loop?.admits(ticks: occurrence.ticks) ?? true else { throw MusicalTimingError.outsideLoop }
        let pass = occurrence.pass
        let ticks = occurrence.ticks
        let anchored = Int128(clock.musical.loopIteration)
        guard pass >= anchored else { throw MusicalTimingError.historyUnavailable }
        if pass == anchored {
            return try add(multiply(Int128(clock.anchor.sample.frame), unitsPerFrame),
                           units(clock, from: clock.musical.ticks, to: ticks))
        }
        guard let loop, clock.musical.ticks <= loop.endTicks else {
            throw MusicalTimingError.historyUnavailable
        }
        let period = rounded(units(clock, from: loop.startTicks, to: loop.endTicks))
        let start = try add(wrapFrame(clock, loop: loop), multiply(pass - anchored - 1, period))
        return try add(multiply(start, unitsPerFrame), units(clock, from: loop.startTicks, to: ticks))
    }

    /// First forward grid occurrence. Full virtual passes are skipped arithmetically, never walked.
    static func nextBoundary(at frame: Int64, grid: Int64, clock: MusicalClockMap,
                             loop: LoopRange?) throws -> MusicalOccurrence {
        try validate(clock)
        guard grid > 0 else { throw MusicalTimingError.invalidTarget }
        let exact = clock.exactTicks(atFrame: frame)
        let boundary = ExactMath.ceilDiv(exact.numerator, exact.denominator * Int128(grid)) * Int128(grid)
        let pass = Int128(clock.musical.loopIteration)
        guard let loop else {
            guard boundary >= 0 else { throw MusicalTimingError.invalidTarget }
            return try MusicalOccurrence(pass: pass, ticks: narrow(boundary))
        }
        let wrap = try wrapFrame(clock, loop: loop)
        if Int128(frame) < wrap || clock.musical.ticks > loop.endTicks {
            if boundary >= Int128(loop.startTicks), boundary <= Int128(loop.endTicks) {
                return MusicalOccurrence(pass: pass, ticks: Int64(boundary))
            }
            if boundary < Int128(loop.startTicks) || clock.musical.ticks > loop.endTicks {
                throw MusicalTimingError.outsideLoop
            }
        }
        return try futureBoundary(at: frame, grid: grid, clock: clock, loop: loop, wrap: wrap)
    }

    private static func futureBoundary(at frame: Int64, grid: Int64, clock: MusicalClockMap,
                                       loop: LoopRange, wrap: Int128) throws -> MusicalOccurrence {
        let first = ExactMath.ceilDiv(Int128(loop.startTicks), Int128(grid))
        let last = Int128(loop.endTicks) / Int128(grid)
        guard first <= last else { throw MusicalTimingError.outsideLoop }
        let period = rounded(units(clock, from: loop.startTicks, to: loop.endTicks))
        guard period > 0 || Int128(frame) <= wrap else { throw MusicalTimingError.nonAdvancingLoop }
        var skipped = period == 0 ? 0 : max(0, ExactMath.floorDiv(Int128(frame) - wrap, period))
        let start = try add(wrap, multiply(skipped, period))
        let threshold = try multiply(add(Int128(frame), -start), unitsPerFrame)
        var lower = first
        var upper = last + 1
        // At most 64 bisections over the declared Int64 tick range.
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let ticks = try narrow(middle * Int128(grid))
            if units(clock, from: loop.startTicks, to: ticks) < threshold { lower = middle + 1 } else { upper = middle }
        }
        if lower > last { skipped = try add(skipped, 1); lower = first }
        return try MusicalOccurrence(pass: add(add(Int128(clock.musical.loopIteration), 1), skipped),
                                     ticks: narrow(lower * Int128(grid)))
    }

    /// Quantize a covered origin through the current map and the actual origin anchor/pass.
    /// Unlike a fallback horizon, an origin never acquires hypothetical intervening passes.
    static func candidates(for target: MusicalTarget, origin: MusicalOrigin)
        throws -> (forward: Result<MusicalOccurrence, MusicalTimingError>, previous: MusicalOccurrence?) {
        let clock = origin.clock
        try validate(clock)
        let pass = Int128(clock.musical.loopIteration)
        switch target {
        case .absolute(let ticks):
            guard ticks >= 0 else { throw MusicalTimingError.invalidTarget }
            guard origin.loop?.admits(ticks: ticks) ?? true else { throw MusicalTimingError.outsideLoop }
            return (.success(MusicalOccurrence(pass: pass, ticks: ticks)), nil)
        case .grid(let grid):
            guard grid > 0 else { throw MusicalTimingError.invalidTarget }
            return try gridCandidates(grid: grid, origin: origin)
        }
    }

    private static func gridCandidates(grid: Int64, origin: MusicalOrigin)
        throws -> (forward: Result<MusicalOccurrence, MusicalTimingError>, previous: MusicalOccurrence?) {
        var frame = origin.isRunning ? origin.exactFrame : MusicalFrame(origin.clock.anchor.sample.frame)
        var end: MusicalFrame?
        if let loop = origin.loop {
            let units = try add(multiply(Int128(origin.clock.anchor.sample.frame), unitsPerFrame),
                                units(origin.clock, from: origin.clock.musical.ticks, to: loop.endTicks))
            let exactEnd = MusicalFrame(units: units)
            end = exactEnd
            if origin.clock.musical.ticks <= loop.endTicks, frame > exactEnd,
               frame < MusicalFrame(integer: rounded(units)) {
                frame = exactEnd
            }
        }
        let bounds = try gridBounds(at: frame, grid: grid, clock: origin.clock)
        var forward = bounds.forward
        let pass = Int128(origin.clock.musical.loopIteration)
        var forwardPass = pass
        if let loop = origin.loop, let end {
            if frame <= end, forward > Int128(loop.endTicks) {
                forwardPass += 1
                forward = ExactMath.ceilDiv(Int128(loop.startTicks), Int128(grid)) * Int128(grid)
            }
        }
        let next: Result<MusicalOccurrence, MusicalTimingError>
        if let loop = origin.loop, forward < Int128(loop.startTicks) || forward > Int128(loop.endTicks) {
            next = .failure(.outsideLoop)
        } else if forward < 0 {
            next = .failure(.invalidTarget)
        } else if let ticks = Int64(exactly: forward) {
            next = .success(MusicalOccurrence(pass: forwardPass, ticks: ticks))
        } else { next = .failure(.overflow) }
        return (next, previousBoundary(pass: pass, ticks: bounds.previous, grid: grid, loop: origin.loop))
    }

    /// At most 64 comparisons, including a sentinel for an unrepresentable forward boundary.
    static func gridBounds(at frame: MusicalFrame, grid: Int64, clock: MusicalClockMap)
        throws -> (forward: Int128, previous: Int128) {
        try validate(clock)
        guard grid > 0 else { throw MusicalTimingError.invalidTarget }
        let base = try multiply(Int128(clock.anchor.sample.frame), unitsPerFrame)
        func coordinate(_ index: Int128) throws -> MusicalFrame {
            let ticks = try narrow(index * Int128(grid))
            return try MusicalFrame(units: add(base, units(clock, from: clock.musical.ticks, to: ticks)))
        }
        let last = Int128(Int64.max) / Int128(grid)
        var lower: Int128 = 0
        var upper = last + 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if try coordinate(middle) < frame { lower = middle + 1 } else { upper = middle }
        }
        let forward = lower * Int128(grid)
        var previous = forward - Int128(grid)
        if lower <= last, try coordinate(lower) == frame { previous = forward }
        return (forward, previous)
    }

    static func previousBoundary(pass: Int128, ticks: Int128, grid: Int64, loop: LoopRange?) -> MusicalOccurrence? {
        guard grid > 0, pass >= 0 else { return nil }
        var iteration = pass
        var previous = min(ticks, Int128(loop?.endTicks ?? Int64.max))
        if previous >= 0 { previous = previous / Int128(grid) * Int128(grid) }
        if let loop, previous < Int128(loop.startTicks) {
            iteration -= 1
            previous = Int128(loop.endTicks) / Int128(grid) * Int128(grid)
        }
        guard previous >= 0, iteration >= 0 else { return nil }
        guard let ticks = Int64(exactly: previous), loop?.admits(ticks: ticks) ?? true else { return nil }
        return MusicalOccurrence(pass: iteration, ticks: ticks)
    }

    static func isRetroactive(_ assigned: Int128, at frame: MusicalFrame, milliseconds: Int, rate: Int) throws -> Bool {
        guard (0...120).contains(milliseconds) else { throw MusicalTimingError.invalidTarget }
        guard MediaNominalRate.isValid(rate) else { throw MusicalTimingError.invalidContext }
        let projected = MusicalFrame(units: assigned)
        guard frame >= projected else { return false }
        let whole = try add(frame.whole, -projected.whole)
        let window = Int128(milliseconds) * Int128(rate)
        guard whole <= window / 1000 + 1 else { return false }
        // Only a bounded window reaches the denominator product; a full-width frame never does.
        let denominator = frame.denominator * unitsPerFrame
        let elapsed = try add(multiply(whole, denominator),
                              frame.numerator * unitsPerFrame - projected.numerator * frame.denominator)
        return try multiply(elapsed, 1000) <= multiply(window, denominator)
    }
}
