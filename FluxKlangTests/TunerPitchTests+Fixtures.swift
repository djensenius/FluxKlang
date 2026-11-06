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

/// Edge and sweep tests built on the fixtures above: the band tolerance, sparse sweeps of weak-odd tones and of
/// high sines, and a dip between two lags.
extension TunerPitchTests {
    @Test
    func aReadingMayExceedABandEdgeByTheToleranceOnly() throws {
        // Brackets the tolerance by behaviour: above the worst measured bias (1.78 cents), below 10 cents.
        func read(_ frequency: Double, _ estimator: inout PitchEstimator, seed: UInt64 = 1) throws -> TunerReading {
            try estimator.analyze(Self.sine(frequency, rate: estimator.configuration.sampleRate,
                                            count: estimator.configuration.windowSize, seed: seed))
        }
        for rate in [44_100, 48_000] {
            // The parabola reads a 2000 Hz sine up to 1.78 cents sharp, past the band's top: it is still reported.
            var estimator = try PitchEstimator(configuration: Self.configuration(rate: rate))
            for (index, frequency) in [2000.0, 1999, 30, 30.05].enumerated() {
                let pitch = try #require(try read(frequency, &estimator, seed: UInt64(index + 100)).pitch)
                let error = Self.cents(pitch.frequency, from: frequency)
                #expect(abs(error) <= Self.edgeSineBoundCents, "\(frequency) Hz at \(rate): \(error) cents")
            }
            // 10 or 25 cents beyond an edge is out of band (below 30 Hz the dip lies past the longest lag).
            for cents in [10.0, 25] {
                #expect(try read(2000 * exp2(cents / 1200), &estimator) == .noPitch(.outOfBand), "\(cents)")
                #expect(try read(30 * exp2(-cents / 1200), &estimator) == .noPitch(.outOfBand), "\(cents)")
            }
            // With a 2500 Hz floor the search reaches 80 cents or more below it, so the band check itself refuses a
            // tone 10 cents under the floor.
            var high = try PitchEstimator(configuration: TunerConfiguration.make(
                sampleRate: rate, minimumFrequency: 2500, maximumFrequency: 5000))
            #expect(try read(2500, &high).pitch != nil)
            #expect(try read(2500 * exp2(-10.0 / 1200), &high) == .noPitch(.outOfBand))
        }
    }

    @Test
    func weakOddTonesFrom41To650HzAreWithinTheirBound() throws {
        // A sparse sweep. Near 500 to 650 Hz the doubled dip is narrow, and a parabola fitted one sample off its
        // minimum would miss by 0.45 to 1.0 cents.
        let frequencies = [41.5, 58, 77.5, 104, 139, 186, 249, 333, 445, 506.5, 587.5, 622.5, 638.5, 650]
        for rate in [44_100, 48_000] {
            var estimator = try PitchEstimator(configuration: Self.configuration(rate: rate))
            for frequency in frequencies {
                for seed in UInt64(1)...2 {
                    let frame = Self.weakOddTone(frequency, rate: rate, count: 4096, seed: seed)
                    let label = "\(frequency) Hz at \(rate), seed \(seed)"
                    let pitch = try #require(try estimator.analyze(frame).pitch, "\(label)")
                    let error = Self.cents(pitch.frequency, from: frequency)
                    #expect(abs(error) <= Self.weakOddBoundCents, "\(label): \(error) cents")
                }
            }
        }
    }

    @Test
    func aDipBetweenTwoLagsAboveTheThresholdIsNotReadAnOctaveLow() throws {
        // Copilot's fixture: period 9.5 at 44.1 kHz. d′ at lags 9 and 10 both stay above a 0.05 threshold, but the
        // refined dip between them is below it; without the off-grid rule the search ran on to lag 19 and read
        // 2323.95 Hz at confidence 1.
        let frequency = 44_100.0 / 9.5
        var estimator = try PitchEstimator(configuration: TunerConfiguration.make(
            sampleRate: 44_100, maximumFrequency: 5000, threshold: 0.05))
        for seed in UInt64(1)...4 {
            let frame = Self.sine(frequency, rate: 44_100, count: estimator.configuration.windowSize, seed: seed)
            let pitch = try #require(try estimator.analyze(frame).pitch, "seed \(seed)")
            let error = Self.cents(pitch.frequency, from: frequency)
            #expect(abs(error) <= 5, "seed \(seed): \(error) cents")
            #expect(pitch.confidence > estimator.configuration.minimumConfidence, "seed \(seed): \(pitch.confidence)")
        }
        // A sawtooth at 1664.3 Hz (period 26.5) in the default band read 832 Hz the same way.
        var saw = try PitchEstimator(configuration: TunerConfiguration.make(sampleRate: 44_100, threshold: 0.05))
        let pitch = try #require(try saw.analyze(Self.saw(1664.3, rate: 44_100, count: 4096)).pitch)
        #expect(abs(Self.cents(pitch.frequency, from: 1664.3)) <= Self.harmonicBoundCents, "\(pitch.frequency)")
    }

    @Test
    func sinesFrom1To5kHzAreNeverReadAnOctaveLow() throws {
        // A sparse sweep in 100 Hz steps, plus every half-integer period in the band (where a dip falls midway
        // between two lags), at low thresholds and both rates. Near the top some sines read out of band (the
        // parabola's bias; see the header), but no reading may be an octave low.
        for rate in [44_100, 48_000] {
            let halfPeriods = (8...48).map { Double(rate) / (Double($0) + 0.5) }.filter { (1000...5000).contains($0) }
            let frequencies = Array(stride(from: 1000.0, through: 5000, by: 100)) + halfPeriods
            let frames = frequencies.map { Self.sine($0, rate: rate, count: 4096) }
            for threshold in [0.05, 0.08, 0.1] {
                var estimator = try PitchEstimator(configuration: TunerConfiguration.make(
                    sampleRate: rate, maximumFrequency: 5000, threshold: threshold))
                for (frequency, frame) in zip(frequencies, frames) {
                    guard let pitch = try estimator.analyze(frame).pitch else { continue }
                    #expect(pitch.frequency >= 0.75 * frequency, "\(frequency) Hz at \(rate), \(threshold)")
                }
            }
        }
    }
}
