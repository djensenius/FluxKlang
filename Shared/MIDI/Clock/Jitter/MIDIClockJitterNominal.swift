//
//  MIDIClockJitterNominal.swift
//  FluxKlang
//
//  The expected interval between MIDI clock pulses, the per-mille tolerance a window is judged against and the
//  verdict. Integers only; the interval and the tolerance are built through throwing factories.
//

/// The expected host ticks between two consecutive pulses, as the exact ratio `spanTicks / pulses`.
struct MIDIClockJitterNominal: Equatable, Sendable {
    static let spanTicksRange: ClosedRange<Int128> = 1...(Int128(1) << 80)
    static let pulsesRange: ClosedRange<Int128> = 1...(Int128(1) << 48)
    static let beatsPerMinuteRange = 20...300
    /// MIDI clock sends 24 pulses per quarter note.
    static let pulsesPerQuarter: Int128 = 24

    /// Host ticks spanned by `pulses` pulses.
    var spanTicks: Int128 { storedSpanTicks }
    /// The number of pulses `spanTicks` covers.
    var pulses: Int128 { storedPulses }

    private let storedSpanTicks: Int128
    private let storedPulses: Int128

    private init(validatedSpanTicks spanTicks: Int128, pulses: Int128) {
        storedSpanTicks = spanTicks
        storedPulses = pulses
    }

    static func make(spanTicks: Int128, pulses: Int128) throws(MIDIClockJitterRefusal) -> Self {
        guard spanTicksRange.contains(spanTicks) else { throw .nominalSpanOutOfRange }
        guard pulsesRange.contains(pulses) else { throw .nominalPulsesOutOfRange }
        return Self(validatedSpanTicks: spanTicks, pulses: pulses)
    }

    /// The pulse interval at `beatsPerMinute`: a minute of nanoseconds times the timebase denominator over 24
    /// pulses per quarter times the tempo times the timebase numerator (nanoseconds per tick is numer/denom).
    static func make(beatsPerMinute: Int, timebase: HostTimebase) throws(MIDIClockJitterRefusal) -> Self {
        guard beatsPerMinuteRange.contains(beatsPerMinute) else { throw .beatsPerMinuteOutOfRange(beatsPerMinute) }
        guard timebase.numer != 0, timebase.denom != 0 else { throw .invalidTimebase }
        let nanosPerMinute = ExactMath.nanosPerSecond * 60
        return try make(
            spanTicks: nanosPerMinute * Int128(timebase.denom),
            pulses: pulsesPerQuarter * Int128(beatsPerMinute) * Int128(timebase.numer)
        )
    }
}

/// How far a pulse interval may stray from nominal, in thousandths of the nominal interval.
struct MIDIClockJitterTolerance: Equatable, Sendable {
    /// Reused from the arbitration policy so that the two ranges cannot drift apart.
    static let perMilleRange = MIDIClockArbitrationPolicy.jitterTolerancePerMilleRange

    var perMille: Int { storedPerMille }

    private let storedPerMille: Int

    private init(validatedPerMille perMille: Int) {
        storedPerMille = perMille
    }

    static func make(perMille: Int) throws(MIDIClockJitterRefusal) -> Self {
        guard perMilleRange.contains(perMille) else { throw .toleranceOutOfRange(perMille) }
        return Self(validatedPerMille: perMille)
    }
}

/// The judgement of a window against a tolerance.
enum MIDIClockJitterVerdict: Equatable, Sendable {
    /// The largest deviation is at most the tolerance; equality counts as within.
    case withinTolerance
    case exceeded
}
