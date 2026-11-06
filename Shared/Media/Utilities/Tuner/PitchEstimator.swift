//
//  PitchEstimator.swift
//  FluxKlang
//
//  The advisory YIN pitch estimator (#111 TU1, ruling Q-TU1; de Cheveigné and
//  Kawahara, 2002). Pure Swift over caller-supplied Float frames; it is
//  advisory only and never used for control.
//
//  For a frame of N samples and the longest lag L (configuration.maximumLag),
//  the integration window is W = N − L ≥ L samples, and for each lag τ in 1…L:
//    d(τ)  = Σ_{j<W} (x[j] − x[j+τ])²                       (difference)
//    d′(τ) = d(τ)·τ / Σ_{k=1…τ} d(k), d′(0) = 1              (cumulative mean normalized)
//  The period is the first lag τ ≥ 2 with d′(τ) < threshold, descended to its
//  local minimum, then refined by a parabola through d′(τ−1), d′(τ), d′(τ+1).
//  Confidence is 1 − the parabola's minimum, limited to 0…1 (ruling).
//
//  Octave check: a dip shaped between a V and a parabola has a true minimum
//  of at least the V's, d′(τ) − |d′(τ−1) − d′(τ+1)| / 2. If that lower bound
//  is at least `octaveCheckFloor` (the dip is shallow in itself, not only off
//  the sample grid), and the refined local minimum of d′ reached by stepping
//  downhill from 2τ is below
//  `octaveCheckRatio` times it, the frame is read at the doubled period.
//  This catches a weak fundamental with weak odd harmonics, whose half-period
//  dip already crosses the threshold. It runs once (no quadrupled period) and
//  only when 2τ + 3 ≤ L. Limit: when that half-period dip spans fewer than
//  about 35 samples (above about 650 Hz at 44.1 or 48 kHz), the bound cannot
//  separate it from an off-grid dip, and such a tone can read an octave high.
//
//  No pitch is ever guessed: silence (RMS at or below the level floor) is
//  `.insufficientSignal`; no dip below the threshold is `.unvoiced` with the
//  best confidence seen; a period outside the band is `.outOfBand`.
//
//  Bounds and allocation: d′ lives in a scratch array of L + 1 Doubles
//  allocated at init. It is computed lazily, in lag order, up to the lags the
//  search needs, so one analysis costs at most W·L multiply-adds.
//  Analysis allocates nothing while the scratch storage is uniquely referenced
//  (a copied estimator copies it once, on its first analysis). Sums are in
//  Double, so finite Float samples can never overflow to infinity or NaN.
//

/// A YIN pitch estimator with storage preallocated for one configuration.
struct PitchEstimator {
    /// The octave check runs only when the first dip's lower bound (its V minimum) is at least this, so a
    /// dip whose true minimum is 0 but falls between samples is never doubled.
    static let octaveCheckFloor = 0.02
    /// The doubled period wins when its refined dip is below this fraction of the first dip's lower bound.
    static let octaveCheckRatio = 0.5

    let configuration: TunerConfiguration
    /// d′ at `0...maximumLag`.
    private var scratch: [Double]

    init(configuration: TunerConfiguration) {
        self.configuration = configuration
        scratch = [Double](repeating: 0, count: configuration.maximumLag + 1)
    }

    /// The scratch storage's capacity; it never changes after init.
    var scratchCapacity: Int { scratch.capacity }

    mutating func analyze(_ frame: [Float]) throws(TunerRefusal) -> TunerReading {
        try frame.withUnsafeBufferPointer { buffer throws(TunerRefusal) in try analyze(buffer) }
    }

    mutating func analyze(_ frame: ArraySlice<Float>) throws(TunerRefusal) -> TunerReading {
        try frame.withUnsafeBufferPointer { buffer throws(TunerRefusal) in try analyze(buffer) }
    }

    /// Analyses exactly `configuration.windowSize` samples. A refused frame changes nothing observable.
    mutating func analyze(_ frame: UnsafeBufferPointer<Float>) throws(TunerRefusal) -> TunerReading {
        let configuration = configuration
        guard frame.count == configuration.windowSize else {
            throw .frameLengthMismatch(expected: configuration.windowSize, actual: frame.count)
        }
        var energy = 0.0
        for index in frame.indices {
            let sample = frame[index]
            guard sample.isFinite else { throw .nonFiniteSample(index: index) }
            energy += Double(sample) * Double(sample)
        }
        guard energy / Double(frame.count) > configuration.levelFloorPower else {
            return .noPitch(.insufficientSignal)
        }
        let estimate = scratch.withUnsafeMutableBufferPointer { storage in
            var analysis = YINAnalysis(samples: frame, storage: storage, maximumLag: configuration.maximumLag)
            return analysis.estimate(threshold: configuration.threshold)
        }
        switch estimate {
        case .unvoiced(let best):
            return .noPitch(.unvoiced(confidence: Self.confidence(best)))
        case .period(let period, let dip):
            let frequency = Double(configuration.sampleRate) / period
            guard frequency >= configuration.minimumFrequency, frequency <= configuration.maximumFrequency else {
                return .noPitch(.outOfBand)
            }
            return try .pitch(TunerPitch.make(frequency: frequency, confidence: Self.confidence(dip),
                                              reference: configuration.reference))
        }
    }

    /// `1 − dip`, limited to `0...1` (a parabola's minimum can dip just below 0).
    private static func confidence(_ dip: Double) -> Double {
        min(1, max(0, 1 - dip))
    }
}

/// One YIN pass over a frame, computing d′ lazily into preallocated storage.
private struct YINAnalysis {
    enum Estimate {
        /// The refined period in samples and the refined d′ minimum.
        case period(Double, dip: Double)
        /// No d′ fell below the threshold; the smallest d′ seen.
        case unvoiced(best: Double)
    }

    let samples: UnsafeBufferPointer<Float>
    let storage: UnsafeMutableBufferPointer<Double>
    let maximumLag: Int
    let integration: Int
    /// d′ is valid at `0...computed`.
    private var computed = 0
    private var runningSum = 0.0

    init(samples: UnsafeBufferPointer<Float>, storage: UnsafeMutableBufferPointer<Double>, maximumLag: Int) {
        self.samples = samples
        self.storage = storage
        self.maximumLag = maximumLag
        integration = samples.count - maximumLag
        storage[0] = 1
    }

    private func normalized(_ lag: Int) -> Double { storage[lag] }

    /// Computes d′ through `lag` (at most `maximumLag`).
    private mutating func extend(through lag: Int) {
        while computed < lag {
            computed += 1
            var sum = 0.0
            for index in 0..<integration {
                let delta = Double(samples[index]) - Double(samples[index + computed])
                sum += delta * delta
            }
            runningSum += sum
            storage[computed] = runningSum > 0 ? sum * Double(computed) / runningSum : 1
        }
    }

    mutating func estimate(threshold: Double) -> Estimate {
        let last = maximumLag - 1
        var best = Double.infinity
        var lag = 2
        while lag <= last {
            extend(through: lag)
            let value = normalized(lag)
            if value < threshold {
                return octaveChecked(descend(from: lag))
            }
            best = min(best, value)
            lag += 1
        }
        return .unvoiced(best: best)
    }

    /// Moves to the local minimum of d′ reached by stepping downhill within `2...maximumLag − 1`.
    private mutating func descend(from start: Int) -> Int {
        var lag = start
        while true {
            extend(through: lag + 1)
            if lag < maximumLag - 1, normalized(lag + 1) < normalized(lag) {
                lag += 1
            } else if lag > 2, normalized(lag - 1) < normalized(lag) {
                lag -= 1
            } else {
                return lag
            }
        }
    }

    /// A refined dip of d′.
    struct Dip {
        /// The parabola's offset from the integer lag.
        let shift: Double
        /// The parabola's minimum.
        let value: Double
        /// The minimum of the symmetric V through the same three points: a lower bound of the true minimum
        /// for a dip shaped between a V and a parabola.
        let lowerBound: Double
    }

    /// The dip through d′ at `lag − 1`, `lag`, `lag + 1`.
    private func vertex(_ lag: Int) -> Dip {
        let left = normalized(lag - 1)
        let centre = normalized(lag)
        let right = normalized(lag + 1)
        let lowerBound = centre - abs(left - right) / 2
        let curvature = left - 2 * centre + right
        guard curvature > 0 else { return Dip(shift: 0, value: centre, lowerBound: lowerBound) }
        let shift = (left - right) / (2 * curvature)
        return Dip(shift: shift, value: centre - (left - right) * shift / 4, lowerBound: lowerBound)
    }

    private mutating func octaveChecked(_ lag: Int) -> Estimate {
        let first = vertex(lag)
        let doubled = 2 * lag
        // The descent from 2τ needs d′ through 2τ + 1; the margin keeps a doubled dip near L off the edge.
        guard first.lowerBound >= PitchEstimator.octaveCheckFloor, doubled + 3 <= maximumLag else {
            return .period(Double(lag) + first.shift, dip: first.value)
        }
        let candidate = descend(from: doubled)
        let second = vertex(candidate)
        guard second.value < first.lowerBound * PitchEstimator.octaveCheckRatio else {
            return .period(Double(lag) + first.shift, dip: first.value)
        }
        return .period(Double(candidate) + second.shift, dip: second.value)
    }
}
