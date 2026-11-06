import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Tuner pitch estimator")
struct TunerPitchTests {
    /// The accuracy bound for pure sines from 30.9 Hz to 1318.5 Hz (acceptance 1).
    static let sineBoundCents = 1.0
    /// The accuracy bound for the harmonic fixtures: a sawtooth's dip is V-shaped, which the parabola fits less
    /// well at short periods (here the worst, a weak-fundamental E6 sawtooth at 48 kHz, is about 2.6 cents).
    static let harmonicBoundCents = 3.0

    @Test
    func sinesFromLowBToE6AreWithinOneCentAtBothRates() throws {
        for rate in [44_100, 48_000] {
            let configuration = try Self.configuration(rate: rate)
            #expect(configuration.windowSize == 4096)
            var estimator = PitchEstimator(configuration: configuration)
            for (index, note) in Self.notes.enumerated() {
                let frame = Self.sine(note.frequency, rate: rate, count: 4096, seed: UInt64(index + 1))
                let pitch = try #require(try estimator.analyze(frame).pitch, "\(note.name) at \(rate) Hz")
                let error = Self.cents(pitch.frequency, from: note.frequency)
                #expect(abs(error) <= Self.sineBoundCents, "\(note.name) at \(rate) Hz: \(error) cents")
                #expect(pitch.note.name == note.name)
                #expect(abs(pitch.cents) < 0.1 + abs(error), "\(note.name): \(pitch.cents) cents")
                #expect(pitch.confidence > configuration.minimumConfidence && pitch.confidence <= 1)
                // A sine's true d′ minimum is 0, and the parabola finds it off the sample grid: the refined dip is
                // at most 5e-4 (measured 2.1e-4 at E6), where d′ at the nearest lag alone reaches 3.5e-3.
                #expect(1 - pitch.confidence <= 5e-4, "\(note.name) at \(rate) Hz: \(pitch.confidence)")
            }
        }
    }

    @Test
    func detunedSinesReportTheirCents() throws {
        var estimator = try PitchEstimator(configuration: Self.configuration())
        for (index, offset) in [-49.0, -23.5, -3, 3, 17.25, 49].enumerated() {
            let frequency = 110 * exp2(offset / 1200)
            let frame = Self.sine(frequency, rate: 48_000, count: 4096, seed: UInt64(index + 20))
            let pitch = try #require(try estimator.analyze(frame).pitch)
            #expect(pitch.note.name == "A2")
            #expect(abs(pitch.cents - offset) <= Self.sineBoundCents, "\(offset): \(pitch.cents)")
        }
    }

    @Test
    func higherRatesUseLongerWindowsAndStayAccurate() throws {
        for (rate, window) in [(88_200, 8192), (96_000, 8192), (176_400, 16_384), (192_000, 16_384)] {
            let configuration = try Self.configuration(rate: rate)
            #expect(configuration.windowSize == window)
            var estimator = PitchEstimator(configuration: configuration)
            for frequency in [82.407, 440.0] {
                let frame = Self.sine(frequency, rate: rate, count: window)
                let pitch = try #require(try estimator.analyze(frame).pitch)
                #expect(abs(Self.cents(pitch.frequency, from: frequency)) <= Self.sineBoundCents, "\(rate)")
            }
        }
    }

    @Test
    func harmonicTonesWithAWeakFundamentalHaveNoOctaveError() throws {
        for rate in [44_100, 48_000] {
            var estimator = try PitchEstimator(configuration: Self.configuration(rate: rate))
            for (index, note) in Self.notes.enumerated() {
                var fixtures = [
                    ("saw", Self.saw(note.frequency, rate: rate, count: 4096, seed: UInt64(index + 40))),
                    ("weak saw", Self.saw(note.frequency, rate: rate, count: 4096, fundamental: 0.1,
                                          seed: UInt64(index + 60)))
                ]
                // Above about 650 Hz the weak-odd tone's half-period dip is too narrow to bound (see the E6 test).
                if note.frequency <= 440 {
                    fixtures.append(("weak odd", Self.weakOddTone(note.frequency, rate: rate, count: 4096,
                                                                  seed: UInt64(index + 80))))
                }
                for (kind, frame) in fixtures {
                    guard let pitch = try estimator.analyze(frame).pitch else {
                        Issue.record("\(kind) \(note.name) at \(rate): no pitch")
                        continue
                    }
                    #expect(pitch.note.name == note.name, "\(kind) \(note.name) at \(rate): \(pitch.note.name)")
                    let error = Self.cents(pitch.frequency, from: note.frequency)
                    #expect(abs(error) <= Self.harmonicBoundCents, "\(kind) \(note.name) at \(rate): \(error)")
                }
            }
        }
    }

    @Test
    func theOctaveCheckReadsAWeakOddToneAtItsFundamental() throws {
        // Without the check, 220 Hz with weak odd harmonics reads as 440 Hz (its half-period dip).
        var estimator = try PitchEstimator(configuration: Self.configuration())
        let pitch = try #require(try estimator.analyze(Self.weakOddTone(220, rate: 48_000, count: 4096)).pitch)
        #expect(pitch.note.name == "A3")
        #expect(abs(Self.cents(pitch.frequency, from: 220)) <= Self.harmonicBoundCents)
        // At E6 the half-period dip spans about 17 samples and cannot be told from a dip that is merely off the
        // sample grid, so the check does not double it (a documented limit, from about 650 Hz up). Here it reads
        // E7, outside the default band: no pitch, not a wrong note.
        for rate in [44_100, 48_000] {
            var estimator = try PitchEstimator(configuration: Self.configuration(rate: rate))
            let frame = Self.weakOddTone(1318.51, rate: rate, count: 4096)
            #expect(try estimator.analyze(frame) == .noPitch(.outOfBand))
        }
    }

    @Test
    func silenceAndQuietFramesHaveInsufficientSignal() throws {
        let configuration = try Self.configuration()
        var estimator = PitchEstimator(configuration: configuration)
        #expect(try estimator.analyze([Float](repeating: 0, count: 4096)) == .noPitch(.insufficientSignal))
        #expect(try estimator.analyze([Float](repeating: 0, count: 4096)).confidence == 0)
        // −60 dBFS RMS is a sine of amplitude 0.001·√2: 1% below is silence, 1% above is a pitch.
        let floorAmplitude = 0.001 * 2.0.squareRoot()
        let below = Self.sine(440, rate: 48_000, count: 4096, amplitude: floorAmplitude * 0.99)
        let above = Self.sine(440, rate: 48_000, count: 4096, amplitude: floorAmplitude * 1.01)
        #expect(try estimator.analyze(below) == .noPitch(.insufficientSignal))
        #expect(try estimator.analyze(above).pitch?.note.name == "A4")
    }

    @Test
    func noiseAndDirectCurrentAreUnvoicedBelowTheThreshold() throws {
        let configuration = try Self.configuration()
        var estimator = PitchEstimator(configuration: configuration)
        for seed in UInt64(1)...8 {
            let reading = try estimator.analyze(Self.noise(seed: seed, count: 4096))
            guard case .noPitch(.unvoiced(let confidence)) = reading else {
                Issue.record("seed \(seed): \(reading)")
                continue
            }
            // Noise is barely periodic: its best d′ is below 1 but far above the threshold.
            #expect(confidence.isFinite && confidence > 0)
            #expect(confidence < configuration.minimumConfidence, "seed \(seed): \(confidence)")
        }
        // A constant frame has no difference at any lag: d′ is 1 throughout.
        let constant = [Float](repeating: 0.25, count: 4096)
        #expect(try estimator.analyze(constant) == .noPitch(.unvoiced(confidence: 0)))
    }

    @Test
    func periodsOutsideTheBandAreNotReported() throws {
        var estimator = try PitchEstimator(configuration: Self.configuration())
        #expect(try estimator.analyze(Self.sine(3000, rate: 48_000, count: 4096)) == .noPitch(.outOfBand))
        #expect(try estimator.analyze(Self.sine(2100, rate: 48_000, count: 4096)) == .noPitch(.outOfBand))
        #expect(try estimator.analyze(Self.sine(1900, rate: 48_000, count: 4096)).pitch != nil)
        // 25 Hz is below the 30 Hz floor: its period is longer than the longest lag.
        #expect(try estimator.analyze(Self.sine(25, rate: 48_000, count: 4096)).pitch == nil)
        // 29.99 Hz dips at the longest lag searched (1601); refined, its period is just below the floor.
        #expect(try estimator.analyze(Self.sine(29.99, rate: 48_000, count: 4096)) == .noPitch(.outOfBand))
        // At 5 Hz d′ only rises (its best, at lag 2, is above 1), so the confidence is limited to 0.
        let slow = try estimator.analyze(Self.sine(5, rate: 48_000, count: 4096))
        #expect(slow == .noPitch(.unvoiced(confidence: 0)))
    }

    @Test
    func inharmonicTonesAreNotReadAnOctaveLow() throws {
        // A partial at 1.36 times the fundamental leaves d′ ≈ 0.08 at the period and ≈ 0.06 at twice it, so the
        // octave check runs (the dip is shallow in itself) and must keep the fundamental: the doubled dip is not
        // below half the first. The partial pulls the period by about 20 to 29 cents (the tone is not periodic);
        // an octave error would be 1200.
        func frame(_ frequency: Double, count: Int, seed: UInt64) -> [Float] {
            let partial = Self.sine(frequency * 1.36, rate: 48_000, count: count, amplitude: 0.11, seed: seed + 9)
            return zip(Self.sine(frequency, rate: 48_000, count: count, seed: seed), partial).map { $0 + $1 }
        }
        var estimator = try PitchEstimator(configuration: Self.configuration())
        for frequency in [55.0, 110, 220, 440] {
            for seed in UInt64(1)...4 {
                let reading = try estimator.analyze(frame(frequency, count: 4096, seed: seed))
                let pitch = try #require(reading.pitch, "\(frequency) Hz, seed \(seed): \(reading)")
                let error = Self.cents(pitch.frequency, from: frequency)
                #expect(abs(error) < 35, "\(frequency) Hz, seed \(seed): \(error) cents")
                #expect(pitch.confidence < 0.98, "\(frequency) Hz, seed \(seed): \(pitch.confidence)")
            }
        }
        // With a 112 Hz floor the longest lag is 430, and 220 Hz dips at τ = 215 or 216: 2τ + 3 > 430, so the
        // octave check must not run (its descent from 2τ would read past the scratch).
        var short = try PitchEstimator(configuration: TunerConfiguration.make(sampleRate: 48_000,
                                                                              minimumFrequency: 112))
        #expect(short.configuration.maximumLag == 430 && short.configuration.windowSize == 2048)
        for seed in UInt64(1)...4 {
            let pitch = try #require(try short.analyze(frame(220, count: 2048, seed: seed)).pitch)
            #expect(abs(Self.cents(pitch.frequency, from: 220)) < 35, "seed \(seed)")
        }
    }

    @Test
    func theReferenceChangesTheCentsExactly() throws {
        for hertz in [415.0, 432, 442, 466] {
            let reference = try TunerReference.make(hertz: hertz)
            let pitch = try TunerPitch.make(frequency: 440, confidence: 1, reference: reference)
            let position = 69 + Self.cents(440, from: hertz) / 100
            #expect(pitch.note.number == Int((position + 0.5).rounded(.down)))
            #expect(abs(Double(pitch.note.number) + pitch.cents / 100 - position) < 1e-12)
        }
        let sharp = try TunerPitch.make(frequency: 440, confidence: 1, reference: TunerReference.make(hertz: 442))
        #expect(sharp.note.name == "A4" && abs(sharp.cents - Self.cents(440, from: 442)) < 1e-9)
        // One frame estimated against two references: the frequency is the same and the cents differ exactly.
        let frame = Self.sine(440, rate: 48_000, count: 4096)
        var standard = try PitchEstimator(configuration: Self.configuration())
        var baroque = try PitchEstimator(configuration: Self.configuration(reference: 432))
        let atStandard = try #require(try standard.analyze(frame).pitch)
        let atBaroque = try #require(try baroque.analyze(frame).pitch)
        #expect(atStandard.frequency == atBaroque.frequency)
        #expect(abs(atBaroque.cents - atStandard.cents - Self.cents(440, from: 432)) < 1e-9)
    }

    @Test
    func centsRoundToTheNearestNoteWithHalfwayGoingUp() throws {
        for (offset, number, cents) in [(0.49, 69, 49.0), (0.51, 70, -49.0), (-0.49, 69, -49.0), (-0.51, 68, 49.0)] {
            let pitch = try Self.pitch(440, cents: offset * 100)
            #expect(pitch.note.number == number, "\(offset)")
            #expect(abs(pitch.cents - cents) < 1e-9, "\(offset): \(pitch.cents)")
        }
        for step in -200...200 {
            let pitch = try Self.pitch(440, cents: Double(step) / 4)
            #expect(pitch.cents >= -50 && pitch.cents < 50)
        }
    }

    @Test
    func notesHaveScientificNames() {
        let cases = [(69, "A4"), (60, "C4"), (59, "B3"), (23, "B0"), (37, "C♯2"), (0, "C-1"), (-1, "B-2"), (127, "G9")]
        for (number, name) in cases {
            #expect(TunerNote(number: number).name == name)
        }
        #expect(TunerNote(number: -13).pitchClass == 11 && TunerNote(number: -13).octave == -3)
    }

    @Test
    func pitchesAreValidated() throws {
        let reference = TunerReference.standard
        #expect(try TunerPitch.make(frequency: 1, confidence: 0, reference: reference).note.number == -36)
        #expect(try TunerPitch.make(frequency: 20_000, confidence: 1, reference: reference).confidence == 1)
        for frequency in [0.999, 20_000.01, -440, .infinity] {
            #expect(Self.refusal { () throws(TunerRefusal) in
                try TunerPitch.make(frequency: frequency, confidence: 0.5, reference: reference)
            } == .frequencyOutOfRange(frequency))
        }
        for confidence in [-0.000_1, 1.000_1, .infinity] {
            #expect(Self.refusal { () throws(TunerRefusal) in
                try TunerPitch.make(frequency: 440, confidence: confidence, reference: reference)
            } == .confidenceOutOfRange(confidence))
        }
        let nan = Self.refusal { () throws(TunerRefusal) in
            try TunerPitch.make(frequency: .nan, confidence: 0.5, reference: reference)
        }
        guard case .frequencyOutOfRange(let value) = nan, value.isNaN else {
            Issue.record("NaN frequency: \(String(describing: nan))")
            return
        }
    }

    @Test
    func configurationsAreValidatedAtEveryBound() throws {
        typealias Config = TunerConfiguration
        func refused(rate: Int = 48_000, reference: TunerReference = .standard, minimum: Double = 30,
                     maximum: Double = 2000, window: Int? = nil, threshold: Double = 0.15,
                     floor: Double = -60) -> TunerRefusal? {
            Self.refusal { () throws(TunerRefusal) in
                try Config.make(sampleRate: rate, reference: reference, minimumFrequency: minimum,
                                maximumFrequency: maximum, windowSize: window, threshold: threshold,
                                levelFloor: floor)
            }
        }
        for rate in [44_100, 48_000, 88_200, 96_000, 176_400, 192_000] { #expect(refused(rate: rate) == nil) }
        for rate in [0, 44_099, 44_101, 47_999, 192_001] { #expect(refused(rate: rate) == .invalidSampleRate(rate)) }
        for hertz in [415.0, 466] { #expect(try TunerReference.make(hertz: hertz).hertz == hertz) }
        for hertz in [414.999, 466.001, -440, .infinity] {
            #expect(Self.refusal { () throws(TunerRefusal) in try TunerReference.make(hertz: hertz) }
                == .referenceOutOfRange(hertz))
        }
        #expect(Self.refusal { () throws(TunerRefusal) in try TunerReference.make(hertz: .nan) } != nil)
        #expect(TunerReference.standard.hertz == 440)
        // The band: 20…5000 Hz, at least an octave wide.
        #expect(refused(minimum: 20, maximum: 40) == nil && refused(minimum: 2500, maximum: 5000) == nil)
        for (minimum, maximum) in [(19.999, 2000.0), (30, 5000.001), (30, 59.999), (1000, 1999), (.nan, 2000)] {
            guard case .frequencyRangeInvalid = refused(minimum: minimum, maximum: maximum) else {
                Issue.record("\(minimum)…\(maximum) accepted")
                continue
            }
        }
        // The window: 2048…32768, and two of the longest lags (3202 at 48 kHz from 30 Hz).
        #expect(Config.requiredWindowSize(sampleRate: 48_000, minimumFrequency: 30) == 3202)
        #expect(refused(window: 3202) == nil && refused(window: 32_768) == nil)
        #expect(refused(window: 3201) == .windowTooShort(windowSize: 3201, required: 3202))
        #expect(refused(window: 32_769) == .windowSizeOutOfRange(32_769))
        #expect(refused(minimum: 50, window: 2048) == nil)
        #expect(refused(minimum: 50, window: 2047) == .windowSizeOutOfRange(2047))
        #expect(refused(rate: 192_000, minimum: 20) == nil)
        #expect(try Config.make(sampleRate: 192_000, minimumFrequency: 20).windowSize == 32_768)
        #expect(try Config.make(sampleRate: 48_000, minimumFrequency: 100).windowSize == 2048)
        for (threshold, accepted) in [(0.05, true), (0.5, true), (0.049_9, false), (0.500_1, false)] {
            #expect((refused(threshold: threshold) == nil) == accepted)
        }
        #expect(refused(threshold: 0.6) == .thresholdOutOfRange(0.6))
        for (floor, accepted) in [(-120.0, true), (-20, true), (-120.001, false), (-19.999, false)] {
            #expect((refused(floor: floor) == nil) == accepted)
        }
        #expect(refused(floor: -10) == .levelFloorOutOfRange(-10))
        let standard = try Config.make(sampleRate: 48_000)
        #expect(standard.maximumLag == 1601 && standard.minimumConfidence == 1 - 0.15)
        #expect(abs(standard.levelFloorPower - 1e-6) < 1e-18)
    }

    @Test
    func framesAreCheckedAndARefusalChangesNothing() throws {
        var estimator = try PitchEstimator(configuration: Self.configuration())
        let capacity = estimator.scratchCapacity
        let frame = Self.sine(220, rate: 48_000, count: 4096)
        let before = try estimator.analyze(frame)
        for count in [0, 4095, 4097] {
            let short = [Float](repeating: 0.1, count: count)
            #expect(Self.refusal { () throws(TunerRefusal) in try estimator.analyze(short) }
                == .frameLengthMismatch(expected: 4096, actual: count))
        }
        for (index, value) in [(0, Float.nan), (2047, .infinity), (4095, -.infinity), (17, .signalingNaN)] {
            var broken = frame
            broken[index] = value
            #expect(Self.refusal { () throws(TunerRefusal) in try estimator.analyze(broken) }
                == .nonFiniteSample(index: index))
        }
        #expect(try estimator.analyze(frame) == before)
        #expect(estimator.scratchCapacity == capacity)
    }

    @Test
    func extremeFiniteSamplesNeverProduceNaN() throws {
        var estimator = try PitchEstimator(configuration: Self.configuration())
        let loud = Self.sine(110, rate: 48_000, count: 4096).map { $0 / 0.5 * 3.4e38 }
        #expect(loud.allSatisfy { $0.isFinite })
        let pitch = try #require(try estimator.analyze(loud).pitch)
        #expect(abs(Self.cents(pitch.frequency, from: 110)) <= Self.sineBoundCents)
        let square = (0..<4096).map { $0 % 2 == 0 ? Float.greatestFiniteMagnitude : -Float.greatestFiniteMagnitude }
        let reading = try estimator.analyze(square)
        #expect(reading.confidence.isFinite && (0...1).contains(reading.confidence))
        if let pitch = reading.pitch { #expect(pitch.frequency.isFinite && pitch.cents.isFinite) }
        let tiny = (0..<4096).map { $0 % 2 == 0 ? Float.leastNonzeroMagnitude : 0 }
        #expect(try estimator.analyze(tiny) == .noPitch(.insufficientSignal))
    }

    @Test
    func analysisReusesItsPreallocatedScratch() throws {
        let configuration = try Self.configuration()
        var estimator = PitchEstimator(configuration: configuration)
        let capacity = estimator.scratchCapacity
        #expect(capacity >= configuration.maximumLag + 1)
        // A long signal analysed by hops, through arrays, slices and unsafe buffers: the scratch never grows.
        let signal = Self.sine(146.832, rate: 48_000, count: 4096 + 7 * 512)
        var readings: [TunerReading] = []
        for hop in 0..<8 {
            let slice = signal[(hop * 512)..<(hop * 512 + 4096)]
            readings.append(try estimator.analyze(slice))
            readings.append(try estimator.analyze(Array(slice)))
            readings.append(try slice.withUnsafeBufferPointer { buffer throws(TunerRefusal) in
                try estimator.analyze(buffer)
            })
            #expect(estimator.scratchCapacity == capacity)
        }
        for reading in readings {
            let pitch = try #require(reading.pitch)
            #expect(pitch.note.name == "D3" && abs(pitch.cents) <= Self.sineBoundCents)
        }
        // A copy shares the scratch until its first analysis, and then has its own of the same size.
        var copy = estimator
        _ = try copy.analyze(signal[0..<4096])
        #expect(copy.scratchCapacity == capacity && estimator.scratchCapacity == capacity)
    }
}
