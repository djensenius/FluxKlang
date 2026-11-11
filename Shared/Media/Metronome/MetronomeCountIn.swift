//
//  MetronomeCountIn.swift
//  FluxKlang
//
//  Count-in clicks before the anchor (#111 K1), at the tempo of the map's
//  first segment (the one at tick 0). The anchor is the integer frame of
//  tick 0 (`frame(atTicks: 0)`); the caller places each click at
//  `anchor − framesBeforeAnchor`. Each click's absolute frame extrapolates the
//  first segment's exact rational line back from the clock map's own anchor
//  (keeping its fractional phase) and is rounded half-up once, exactly as
//  `MusicalClockMap.frame(atTicks:)` does; no duration is rounded on its own.
//  An absolute frame outside Int64 refuses the whole count-in with
//  `.clock(.overflow)`.
//

enum MetronomeCountIn {
    static let maximumBars = 4

    /// `bars` bars of clicks ending just before the anchor, earliest first. At most
    /// 4 bars × 64 beats × 8 subdivisions = 2,048 clicks, so no click cap is needed.
    static func clicks(bars: Int, configuration: MetronomeConfiguration, clock: MusicalClockMap,
                       current: ClockGenerationSnapshot) throws(MetronomeRefusal) -> [MetronomeCountInClick] {
        guard (0...maximumBars).contains(bars) else { throw .countInBarsOutOfRange(bars) }
        try MetronomeGrid.validate(clock, current: current)
        guard let first = clock.map.segments.first else { throw .clock(.invalidMap) }
        let anchor = try MetronomeGrid.mapped { () throws(ClockMapError) in try clock.frame(atTicks: 0) }
        let rate = Int128(clock.nominalRate)
        let unitsPerFrame = Int128(MusicalTime.ticksPerQuarter) * ExactMath.microsPerSecond
        // The exact frame of tick 0 in units, before any rounding.
        let origin = Int128(clock.anchor.sample.frame) * unitsPerFrame
            - units(toTicks: clock.musical.ticks, segments: clock.map.segments, rate: rate)
        let unitsPerTick = Int128(first.microsPerQuarter) * rate
        let total = configuration.barTicks * Int64(bars)
        var clicks: [MetronomeCountInClick] = []
        var beatStart: Int64 = 0
        while beatStart < total {
            for index in 0..<configuration.subdivisions {
                let ticks = beatStart + configuration.offset(ofSubdivision: index) - total
                let absolute = ExactMath.roundHalfUp(origin + Int128(ticks) * unitsPerTick, unitsPerFrame)
                guard absolute >= Int128(Int64.min) else { throw .clock(.overflow) }
                guard let frames = UInt64(exactly: Int128(anchor) - absolute) else { throw .clock(.overflow) }
                let position = configuration.position(beatStart: beatStart, subdivision: index)
                clicks.append(MetronomeCountInClick(framesBeforeAnchor: frames, bar: Int(position.bar),
                                                    beat: position.beat, subdivision: index,
                                                    accent: position.accent))
            }
            beatStart += configuration.beatTicks
        }
        return clicks
    }

    /// Units (`1 / (ticksPerQuarter · 10⁶)` frame) from tick 0 to `ticks` along the tempo map, the
    /// first segment extending before tick 0 as in `MusicalClockMap`.
    static func units(toTicks ticks: Int64, segments: [TempoSegment], rate: Int128) -> Int128 {
        guard let first = segments.first, ticks > 0 else {
            return Int128(ticks) * Int128(segments.first?.microsPerQuarter ?? 0) * rate
        }
        var total: Int128 = 0
        var position = first.atTicks
        for (index, segment) in segments.enumerated() where position < ticks {
            let next = index + 1 < segments.count ? min(segments[index + 1].atTicks, ticks) : ticks
            total += (Int128(next) - Int128(position)) * Int128(segment.microsPerQuarter) * rate
            position = next
        }
        return total
    }
}
