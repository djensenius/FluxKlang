//
//  MetronomeGrid.swift
//  FluxKlang
//
//  Window queries on the metronome click grid (#111 K1). Beat starts are exact
//  multiples of the beat length from tick 0; each subdivision is rounded once
//  from its own beat start. Frames come only from
//  `MusicalClockMap.frame(atTicks:)`. Nothing is rendered.
//

/// The live generations a clock map must match before it is used.
struct MetronomeGenerations: Hashable, Sendable {
    let sample: Generation
    let transport: Generation
    let musicalMap: Generation
}

enum MetronomeGrid {
    /// The most clicks one query returns; a fuller window is refused, never truncated.
    static let maximumClicks = 4096

    /// Refuses a clock map whose sample, transport or tempo map generation is not live.
    static func validate(_ clock: MusicalClockMap, current: MetronomeGenerations) throws(MetronomeRefusal) {
        guard clock.anchor.sample.generation == current.sample else { throw .clock(.staleSampleGeneration) }
        guard clock.musical.transport == current.transport else { throw .clock(.staleTransport) }
        guard clock.map.revision == current.musicalMap else { throw .staleMusicalMap }
    }

    /// The clicks whose frame lies in `[start, end)`, in frame order. Clicks start at tick 0;
    /// earlier positions belong to a count-in. The map extrapolates ticks linearly, so around a
    /// loop wrap the caller splits the window at the wrap frame and queries each part with the
    /// clock map of its own pass.
    ///
    /// Fail-closed: if any tick or frame visited before the end of the window is found does not fit
    /// in `Int64`, the whole window is refused with `.clock(.overflow)` and no clicks are returned.
    static func clicks(from start: Int64, to end: Int64, configuration: MetronomeConfiguration,
                       clock: MusicalClockMap, current: MetronomeGenerations) throws(MetronomeRefusal)
        -> [MetronomeClick] {
        guard start <= end else { throw .invalidWindow(start: start, end: end) }
        try validate(clock, current: current)
        guard start < end else { return [] }
        let beat = configuration.beatTicks
        let boundary = try mapped { () throws(ClockMapError) in try clock.boundary(atOrAfterFrame: start, grid: beat) }
        // Clicks of the beat before the first beat at or after `start` can still lie in the window; earlier
        // beats cannot, as clicks are at least 240 ticks apart: over 41 frames even at the fastest tempo
        // (60,000 µs per quarter) and the lowest rate (44.1 kHz), so well over the ½ frame rounding reach.
        let (previous, underflow) = boundary.subtractingReportingOverflow(beat)
        guard !underflow else { throw .clock(.overflow) }
        var beatStart = max(0, previous)
        var clicks: [MetronomeClick] = []
        while true {
            for index in 0..<configuration.subdivisions {
                let (ticks, overflow) = beatStart.addingReportingOverflow(configuration.offset(ofSubdivision: index))
                guard !overflow else { throw .clock(.overflow) }
                let frame = try mapped { () throws(ClockMapError) in try clock.frame(atTicks: ticks) }
                guard frame < end else { return clicks }
                guard frame >= start else { continue }
                guard clicks.count < maximumClicks else { throw .tooManyClicks(limit: maximumClicks) }
                let position = configuration.position(beatStart: beatStart, subdivision: index)
                clicks.append(MetronomeClick(frame: frame, ticks: ticks, bar: position.bar, beat: position.beat,
                                             subdivision: index, accent: position.accent))
            }
            let (next, overflow) = beatStart.addingReportingOverflow(beat)
            guard !overflow else { throw .clock(.overflow) }
            beatStart = next
        }
    }

    static func mapped<Value>(_ body: () throws(ClockMapError) -> Value) throws(MetronomeRefusal) -> Value {
        do {
            return try body()
        } catch {
            throw .clock(error)
        }
    }
}
