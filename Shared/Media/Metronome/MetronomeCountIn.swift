//
//  MetronomeCountIn.swift
//  FluxKlang
//
//  Count-in clicks before the anchor (#111 K1), at the tempo of the map's
//  first segment (the one at tick 0). The anchor is the integer frame of
//  tick 0 (`frame(atTicks: 0)`); the caller places each click at
//  `anchor − framesBeforeAnchor`. That absolute frame is rounded half-up, the
//  same rule as `MusicalClockMap` and the grid, so the offset itself rounds
//  half-down and a count-in equals the map extrapolated before tick 0.
//

enum MetronomeCountIn {
    static let maximumBars = 4

    /// `bars` bars of clicks ending just before the anchor, earliest first. At most
    /// 4 bars × 64 beats × 8 subdivisions = 2,048 clicks, so no click cap is needed.
    static func clicks(bars: Int, configuration: MetronomeConfiguration, clock: MusicalClockMap,
                       current: MetronomeGenerations) throws(MetronomeRefusal) -> [MetronomeCountInClick] {
        guard (0...maximumBars).contains(bars) else { throw .countInBarsOutOfRange(bars) }
        try MetronomeGrid.validate(clock, current: current)
        guard let tempo = clock.map.segments.first?.microsPerQuarter else { throw .clock(.invalidMap) }
        let unitsPerTick = Int128(tempo) * Int128(clock.nominalRate)
        let unitsPerFrame = Int128(MusicalTime.ticksPerQuarter) * ExactMath.microsPerSecond
        let total = configuration.barTicks * Int64(bars)
        var clicks: [MetronomeCountInClick] = []
        var beatStart: Int64 = 0
        while beatStart < total {
            for index in 0..<configuration.subdivisions {
                let ticks = beatStart + configuration.offset(ofSubdivision: index)
                let offset = -ExactMath.roundHalfUp(-Int128(total - ticks) * unitsPerTick, unitsPerFrame)
                guard let frames = UInt64(exactly: offset) else { throw .clock(.overflow) }
                let position = configuration.position(beatStart: beatStart, subdivision: index)
                clicks.append(MetronomeCountInClick(framesBeforeAnchor: frames, bar: Int(position.bar),
                                                    beat: position.beat, subdivision: index,
                                                    accent: position.accent))
            }
            beatStart += configuration.beatTicks
        }
        return clicks
    }
}
