//
//  MIDIClockJitterRefusal.swift
//  FluxKlang
//
//  Typed refusals of the MIDI clock arrival-jitter statistics. A refusal builds no value.
//

/// Why a jitter window, nominal interval or tolerance was refused.
enum MIDIClockJitterRefusal: Error, Equatable, Sendable {
    /// More stamps than the window holds; the payload is the count given.
    case tooManyStamps(Int)
    /// Fewer than two stamps, so no interval exists; the payload is the count given.
    case tooFewStamps(Int)
    /// The nearest-rank percentile is outside 1...100.
    case percentileOutOfRange(Int)
    /// The stamp at `index` is lower than its predecessor; `index` is the first such stamp.
    case nonMonotonicStamps(index: Int)
    /// The nominal span of ticks is outside 1...2^80.
    case nominalSpanOutOfRange
    /// The nominal pulse count is outside 1...2^48.
    case nominalPulsesOutOfRange
    /// The tempo is outside 20...300 beats per minute.
    case beatsPerMinuteOutOfRange(Int)
    /// The host timebase has a zero numerator or denominator.
    case invalidTimebase
    /// The per-mille tolerance is outside the arbitration policy's range.
    case toleranceOutOfRange(Int)
}
