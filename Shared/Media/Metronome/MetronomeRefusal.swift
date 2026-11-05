//
//  MetronomeRefusal.swift
//  FluxKlang
//
//  Typed refusals of the metronome click grid (#111 K1). Clock-map errors,
//  including stale generations, pass through unchanged inside `.clock`.
//

/// Why a metronome configuration, grid query or count-in is refused.
enum MetronomeRefusal: Error, Equatable, Sendable {
    /// The clock map refused, or the map is stale for the live sample or transport generation.
    case clock(ClockMapError)
    /// The clock map's tempo map revision is not the live `musicalMap` generation.
    case staleMusicalMap
    /// `.dottedCompound` needs a numerator divisible by 3 and greater than 3 (6/8, 9/8, 12/8, …).
    case invalidCompoundMeter(numerator: Int, denominator: Int)
    /// Subdivisions must lie in `1...MetronomeConfiguration.maximumSubdivisions`.
    case subdivisionsOutOfRange(Int)
    /// The frame window `[start, end)` has `end < start`.
    case invalidWindow(start: Int64, end: Int64)
    /// The window holds more than `limit` clicks; nothing is returned rather than a truncated list.
    case tooManyClicks(limit: Int)
    /// Count-in bars must lie in `0...MetronomeCountIn.maximumBars`.
    case countInBarsOutOfRange(Int)
}
