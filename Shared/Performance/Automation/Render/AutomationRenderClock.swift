//
//  AutomationRenderClock.swift
//  FluxKlang
//
//  Musical positions of frames for automation rendering (#108 T2), through
//  `MusicalClockMap` only. With a loop the renderer resolves loop passes itself,
//  the same way `MusicalTiming.restartTicks` does: the first wrap is at
//  `frame(atTicks: loop.endTicks)` (equal to `MusicalTiming.wrapFrame`), and
//  every later pass is the clock re-anchored with `loop.startTicks` at the
//  previous wrap frame, so each pass lasts the same whole number of frames.
//  A frame on a wrap belongs to the new pass (it reads the loop start).
//

/// The clock that maps one loop pass (or the whole timeline without a loop).
struct AutomationRenderPass: Hashable, Sendable {
    let clock: MusicalClockMap
    /// The first frame of the next pass, where the transport wraps; `nil` without an active loop.
    let wrapFrame: Int64?
    /// The loop end tick while the loop is active; positions in this pass stay below it.
    let loopEnd: Int64?
    let loopStart: Int64?

    /// The pass that contains `frame`. A loop is active when the clock's anchor lies at or before its end.
    static func containing(_ frame: Int64, clock: MusicalClockMap,
                           loop: LoopRange?) throws(AutomationRenderRefusal) -> Self {
        guard let loop, clock.musical.ticks <= loop.endTicks else {
            return Self(clock: clock, wrapFrame: nil, loopEnd: nil, loopStart: nil)
        }
        let first = try AutomationRenderMath.frame(loop.endTicks, on: clock)
        guard frame >= first else {
            return Self(clock: clock, wrapFrame: first, loopEnd: loop.endTicks, loopStart: loop.startTicks)
        }
        let firstPass = try reanchor(clock, frame: first, ticks: loop.startTicks)
        let (period, overflow) = try AutomationRenderMath.frame(loop.endTicks, on: firstPass)
            .subtractingReportingOverflow(first)
        guard !overflow else { throw .clock(.overflow) }
        guard period > 0 else { throw .nonAdvancingLoop }
        let (elapsed, elapsedOverflow) = frame.subtractingReportingOverflow(first)
        guard !elapsedOverflow else { throw .clock(.overflow) }
        // The anchor lies between `first` and `frame`, so it cannot overflow.
        let anchor = first + elapsed / period * period
        let (wrap, wrapOverflow) = anchor.addingReportingOverflow(period)
        guard !wrapOverflow else { throw .clock(.overflow) }
        let passClock = anchor == first ? firstPass : try reanchor(clock, frame: anchor, ticks: loop.startTicks)
        return Self(clock: passClock, wrapFrame: wrap, loopEnd: loop.endTicks, loopStart: loop.startTicks)
    }

    /// The clock re-anchored with `ticks` at `frame`, on the same generations, map and rate.
    private static func reanchor(_ clock: MusicalClockMap, frame: Int64,
                                 ticks: Int64) throws(AutomationRenderRefusal) -> MusicalClockMap {
        let anchor = ClockAnchor(
            sample: SampleStamp(clock: clock.anchor.sample.clock, generation: clock.anchor.sample.generation,
                                frame: frame),
            host: clock.anchor.host,
            musical: MusicalStamp(transport: clock.musical.transport, musicalMap: clock.musical.musicalMap,
                                  ticks: ticks, loopIteration: clock.musical.loopIteration)
        )
        do {
            return try MusicalClockMap(anchor: anchor, map: clock.map, nominalRate: clock.nominalRate,
                                       currentSample: clock.anchor.sample.generation,
                                       currentTransport: clock.musical.transport)
        } catch {
            throw .clock(error)
        }
    }

    /// The exact position of `frame` in this pass.
    func exactTicks(atFrame frame: Int64) -> AutomationExactTicks {
        let exact = clock.exactTicks(atFrame: frame)
        return AutomationExactTicks(numerator: exact.numerator, denominator: exact.denominator)
    }
}

/// An exact tick position `numerator / denominator` (`denominator > 0`).
struct AutomationExactTicks: Hashable, Sendable {
    let numerator: Int128
    let denominator: Int128

    init(numerator: Int128, denominator: Int128) {
        self.numerator = numerator
        self.denominator = denominator
    }

    init(_ ticks: Int64) {
        self.init(numerator: Int128(ticks), denominator: 1)
    }

    /// Whole ticks and the remainder; comparing these avoids multiplying two wide numerators.
    private var split: (whole: Int128, remainder: Int128) {
        let whole = ExactMath.floorDiv(numerator, denominator)
        return (whole, numerator - whole * denominator)
    }

    /// Whether both name the same rational position.
    func isSame(as other: Self) -> Bool {
        let lhs = split
        let rhs = other.split
        // Remainders are below their denominators (below 2^41), so the products fit.
        return lhs.whole == rhs.whole && lhs.remainder * other.denominator == rhs.remainder * denominator
    }

    /// The position as a `Double`: the whole ticks plus the fraction, so the value never decreases as the
    /// exact position grows within one denominator, and integral positions are exact below 2^53.
    var position: Double {
        let (whole, remainder) = split
        return Double(whole) + Double(remainder) / Double(denominator)
    }
}

/// Typed wrappers around the clock map.
enum AutomationRenderMath {
    static func frame(_ ticks: Int64, on clock: MusicalClockMap) throws(AutomationRenderRefusal) -> Int64 {
        do {
            return try clock.frame(atTicks: ticks)
        } catch {
            throw .clock(error)
        }
    }

    /// `floor(value + ½)` as a frame, refusing values outside `Int64`.
    static func roundedFrame(_ value: Double) throws(AutomationRenderRefusal) -> Int64 {
        let rounded = (value + 0.5).rounded(.down)
        guard let frame = Int64(exactly: rounded) else { throw .clock(.overflow) }
        return frame
    }
}
