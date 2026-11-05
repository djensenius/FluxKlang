//
//  MetronomeClick.swift
//  FluxKlang
//
//  One click of the metronome grid (#111 K1). Clicks are data only: a later
//  slice turns them into `state` or `midi` actions (media-contract.md §11).
//

/// The emphasis of a click. Exactly three levels.
enum MetronomeAccent: Hashable, Sendable {
    /// The downbeat of a bar.
    case bar
    /// Any other beat.
    case beat
    /// A click between beats.
    case subdivision

    init(beat: Int, subdivision: Int) {
        if subdivision != 0 {
            self = .subdivision
        } else {
            self = beat == 0 ? .bar : .beat
        }
    }
}

/// Zero-based bar, beat and subdivision of a grid tick; bar 0 starts at tick 0.
struct MetronomeGridPosition: Hashable, Sendable {
    let bar: Int64
    let beat: Int
    let subdivision: Int

    var accent: MetronomeAccent { MetronomeAccent(beat: beat, subdivision: subdivision) }
}

/// A click at an exact musical tick and the frame the clock map puts it on.
/// `bar`, `beat` and `subdivision` are zero-based; bar 0 starts at tick 0.
struct MetronomeClick: Hashable, Sendable {
    let frame: Int64
    let ticks: Int64
    let bar: Int64
    let beat: Int
    let subdivision: Int
    let accent: MetronomeAccent
}

/// A count-in click, placed by the caller `framesBeforeAnchor` frames before
/// the anchor (the downbeat of bar 0). `bar` is the zero-based count-in bar.
struct MetronomeCountInClick: Hashable, Sendable {
    let framesBeforeAnchor: UInt64
    let bar: Int
    let beat: Int
    let subdivision: Int
    let accent: MetronomeAccent
}
