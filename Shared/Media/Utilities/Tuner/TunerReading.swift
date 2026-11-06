//
//  TunerReading.swift
//  FluxKlang
//
//  The typed advisory tuner stream (#111 TU1): a pitch (Hz, nearest equal-
//  tempered note, cents from it against the A4 reference, confidence) or a
//  typed "no pitch". A reading never carries NaN or infinity, and it is never
//  used for control.
//

import Foundation

/// An equal-tempered note, numbered as MIDI notes (A4 = 69, C4 = 60).
struct TunerNote: Hashable, Sendable {
    /// Pitch-class names from C, sharps only.
    static let pitchClassNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    let number: Int

    /// 0 for C through 11 for B.
    var pitchClass: Int { ((number % 12) + 12) % 12 }

    /// The scientific octave: C4 is middle C.
    var octave: Int { (number - pitchClass) / 12 - 1 }

    /// For example "A4" or "C♯2".
    var name: String { "\(Self.pitchClassNames[pitchClass])\(octave)" }
}

/// A validated pitch estimate. Built only through `make`.
struct TunerPitch: Hashable, Sendable {
    static let frequencyRange: ClosedRange<Double> = 1...20_000

    let frequency: Double
    let reference: TunerReference
    /// The nearest note: `floor(position + ½)`, where `position = 69 + 12·log2(frequency / A4)`.
    let note: TunerNote
    /// Cents from `note`, in `-50 ..< 50`: a pitch exactly halfway rounds up to the higher note.
    let cents: Double
    /// In `0...1`.
    let confidence: Double

    private init(frequency: Double, reference: TunerReference, note: TunerNote, cents: Double, confidence: Double) {
        self.frequency = frequency
        self.reference = reference
        self.note = note
        self.cents = cents
        self.confidence = confidence
    }

    static func make(frequency: Double, confidence: Double,
                     reference: TunerReference) throws(TunerRefusal) -> TunerPitch {
        guard frequency.isFinite, frequencyRange.contains(frequency) else { throw .frequencyOutOfRange(frequency) }
        guard confidence.isFinite, (0...1).contains(confidence) else { throw .confidenceOutOfRange(confidence) }
        let position = 69 + 12 * log2(frequency / reference.hertz)
        let nearest = (position + 0.5).rounded(.down)
        return TunerPitch(frequency: frequency, reference: reference, note: TunerNote(number: Int(nearest)),
                          cents: (position - nearest) * 100, confidence: confidence)
    }
}

/// Why a frame has no pitch.
enum TunerNoPitch: Hashable, Sendable {
    /// The frame is loud enough but not periodic enough: its best normalized difference is not below the
    /// threshold, so `confidence` is at most `TunerConfiguration.minimumConfidence`.
    case unvoiced(confidence: Double)
    /// The frame's RMS level is at or below the level floor (silence).
    case insufficientSignal
    /// The frame is periodic, but its period lies outside the configured band, so no pitch is reported.
    case outOfBand
}

/// One estimator result: a pitch, or a typed "no pitch" (never a guess).
enum TunerReading: Hashable, Sendable {
    case pitch(TunerPitch)
    case noPitch(TunerNoPitch)

    /// The pitch's confidence, an unvoiced frame's confidence, or 0 for silence and out-of-band frames.
    var confidence: Double {
        switch self {
        case .pitch(let pitch): pitch.confidence
        case .noPitch(.unvoiced(let confidence)): confidence
        case .noPitch(.insufficientSignal), .noPitch(.outOfBand): 0
        }
    }

    var pitch: TunerPitch? {
        if case .pitch(let pitch) = self { pitch } else { nil }
    }
}
