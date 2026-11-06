import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A seeded SplitMix64 generator, private to the tuner fixtures.
private struct TunerFixtureSplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Synthesized tuner fixtures: sines, harmonic tones, seeded noise and silence.
extension TunerPitchTests {
    /// Equal-tempered test pitches from low B (B0, 5-string bass) to E6, against A4 = 440 Hz.
    static let notes: [(name: String, frequency: Double)] = [
        ("B0", 30.868), ("E1", 41.203), ("A1", 55.0), ("E2", 82.407), ("A2", 110.0), ("D3", 146.832),
        ("G3", 195.998), ("B3", 246.942), ("E4", 329.628), ("A4", 440.0), ("E5", 659.255), ("A5", 880.0),
        ("C6", 1046.502), ("E6", 1318.510)
    ]

    /// Cents from `reference` to `frequency`.
    static func cents(_ frequency: Double, from reference: Double) -> Double {
        1200 * log2(frequency / reference)
    }

    /// A random phase in `0 ..< 2π`, fixed by `seed`.
    static func phase(seed: UInt64) -> Double {
        var generator = TunerFixtureSplitMix64(seed: seed)
        return Double.random(in: 0..<(2 * Double.pi), using: &generator)
    }

    /// A sum of harmonics: `amplitudes[k]` is the amplitude of harmonic `k + 1`. Harmonics at or above
    /// Nyquist are left out. Each harmonic has a phase fixed by `seed`.
    static func tone(_ frequency: Double, rate: Int, count: Int, amplitudes: [Double], seed: UInt64 = 1,
                     scale: Double = 1) -> [Float] {
        var generator = TunerFixtureSplitMix64(seed: seed)
        let phases = amplitudes.map { _ in Double.random(in: 0..<(2 * Double.pi), using: &generator) }
        let step = 2 * Double.pi * frequency / Double(rate)
        return (0..<count).map { index in
            var value = 0.0
            for (harmonic, amplitude) in amplitudes.enumerated()
            where Double(harmonic + 1) * frequency < Double(rate) / 2 {
                value += amplitude * sin(Double(harmonic + 1) * step * Double(index) + phases[harmonic])
            }
            return Float(value * scale)
        }
    }

    /// A pure sine of amplitude `amplitude` (default −6 dBFS) with a phase fixed by `seed`.
    static func sine(_ frequency: Double, rate: Int, count: Int, amplitude: Double = 0.5,
                     seed: UInt64 = 1) -> [Float] {
        tone(frequency, rate: rate, count: count, amplitudes: [amplitude], seed: seed)
    }

    /// A band-limited sawtooth (harmonic n at 1/n, up to 30 harmonics) scaled to peak about 0.5, with the
    /// fundamental scaled by `fundamental` (0.1 is a weak fundamental, −20 dB).
    static func saw(_ frequency: Double, rate: Int, count: Int, fundamental: Double = 1,
                    seed: UInt64 = 1) -> [Float] {
        let amplitudes = (1...30).map { harmonic in (harmonic == 1 ? fundamental : 1) / Double(harmonic) }
        return tone(frequency, rate: rate, count: count, amplitudes: amplitudes, seed: seed, scale: 0.3)
    }

    /// A weak fundamental and weak odd harmonics over strong even ones, so the half-period dip of d′
    /// already crosses the YIN threshold: only the octave check reads it at the fundamental.
    static func weakOddTone(_ frequency: Double, rate: Int, count: Int, seed: UInt64 = 1) -> [Float] {
        tone(frequency, rate: rate, count: count, amplitudes: [0.1, 1, 0.1, 0.5, 0.1, 0.33, 0.1, 0.25],
             seed: seed, scale: 0.25)
    }

    /// Uniform white noise in `−amplitude ... amplitude`, fixed by `seed`.
    static func noise(seed: UInt64, count: Int, amplitude: Float = 0.5) -> [Float] {
        var generator = TunerFixtureSplitMix64(seed: seed)
        return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    /// Uniform jitter in `−bound ... bound` cents, fixed by `seed`.
    static func jitter(seed: UInt64, count: Int, bound: Double) -> [Double] {
        var generator = TunerFixtureSplitMix64(seed: seed)
        return (0..<count).map { _ in Double.random(in: -bound...bound, using: &generator) }
    }

    static func configuration(rate: Int = 48_000, reference: Double = 440,
                              maximumFrequency: Double = TunerConfiguration.defaultMaximumFrequency,
                              windowSize: Int? = nil) throws -> TunerConfiguration {
        try TunerConfiguration.make(sampleRate: rate, reference: TunerReference.make(hertz: reference),
                                    maximumFrequency: maximumFrequency, windowSize: windowSize)
    }

    /// The refusal `body` throws, or nil if it succeeds.
    static func refusal(_ body: () throws(TunerRefusal) -> some Any) -> TunerRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }

    /// A pitch at `cents` from `base` Hz against A4 = 440 Hz, with confidence 0.9.
    static func pitch(_ base: Double, cents: Double = 0, reference: TunerReference = .standard) throws -> TunerPitch {
        try TunerPitch.make(frequency: base * exp2(cents / 1200), confidence: 0.9, reference: reference)
    }
}
