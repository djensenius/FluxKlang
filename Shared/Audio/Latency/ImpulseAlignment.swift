//
//  ImpulseAlignment.swift
//  FluxKlang
//
//  Deterministic peak-run alignment for integer sample fixtures.
//

/// Which input sequence failed impulse estimation.
enum ImpulseSide: String, Hashable, Sendable {
    case stimulus
    case response
}

/// Why an impulse policy or fixture cannot produce an offset estimate.
enum ImpulseRefusal: Error, Hashable, Sendable {
    case invalidMinimumPeak
    case invalidDominance
    case emptySequence(ImpulseSide)
    case sequenceTooLong(ImpulseSide, count: Int)
    case silence(ImpulseSide)
    case noPeak(ImpulseSide)
    case ambiguousPeaks(ImpulseSide, winner: ImpulsePeak, competitor: ImpulsePeak)
}

/// Caller-selected minimum peak magnitude and competitor dominance ratio.
struct ImpulsePolicy: Hashable, Sendable {
    let minimumPeak: UInt32
    let dominance: UInt32

    private init(minimumPeak: UInt32, dominance: UInt32) {
        self.minimumPeak = minimumPeak
        self.dominance = dominance
    }

    /// Requires positive thresholds; no policy default is imposed by the model.
    static func make(minimumPeak: UInt32, dominance: UInt32) throws(ImpulseRefusal) -> Self {
        guard minimumPeak > 0 else { throw .invalidMinimumPeak }
        guard dominance > 0 else { throw .invalidDominance }
        return Self(minimumPeak: minimumPeak, dominance: dominance)
    }
}

/// One maximal equal-magnitude run identified as a local peak.
struct ImpulsePeak: Hashable, Sendable {
    let index: Int
    let plateauLength: Int
    let magnitude: UInt32

    fileprivate init(index: Int, plateauLength: Int, magnitude: UInt32) {
        self.index = index
        self.plateauLength = plateauLength
        self.magnitude = magnitude
    }
}

/// The signed response-minus-stimulus frame offset and plateau-derived uncertainty.
struct ImpulseOffsetEstimate: Hashable, Sendable {
    let stimulus: ImpulsePeak
    let response: ImpulsePeak

    fileprivate init(stimulus: ImpulsePeak, response: ImpulsePeak) {
        self.stimulus = stimulus
        self.response = response
    }

    /// Positive means the response peak follows the stimulus peak.
    var offsetFrames: Int64 { Int64(response.index) - Int64(stimulus.index) }

    /// Sum of the two plateau index spans; each endpoint is chosen at its earliest sample.
    var uncertaintyFrames: Int64 {
        Int64(stimulus.plateauLength - 1) + Int64(response.plateauLength - 1)
    }
}

/// Finds unique sufficiently strong local peak runs and reports their integer offset.
enum ImpulseAlignment {
    static let maximumSamples = 1_048_576

    /// Estimates response minus stimulus; ties inside a plateau choose the earliest index.
    static func estimate(stimulus: [Int32], response: [Int32],
                         policy: ImpulsePolicy) throws(ImpulseRefusal) -> ImpulseOffsetEstimate {
        let stimulusPeak = try peak(in: stimulus, side: .stimulus, policy: policy)
        let responsePeak = try peak(in: response, side: .response, policy: policy)
        return ImpulseOffsetEstimate(stimulus: stimulusPeak, response: responsePeak)
    }

    private static func peak(in samples: [Int32], side: ImpulseSide,
                             policy: ImpulsePolicy) throws(ImpulseRefusal) -> ImpulsePeak {
        guard !samples.isEmpty else { throw .emptySequence(side) }
        guard samples.count <= maximumSamples else { throw .sequenceTooLong(side, count: samples.count) }
        guard samples.contains(where: { $0 != 0 }) else { throw .silence(side) }

        let runs = magnitudeRuns(samples)
        guard let maximum = runs.map(\.magnitude).max(), maximum >= policy.minimumPeak, runs.count > 1 else {
            throw .noPeak(side)
        }
        let peaks = localPeaks(runs)
        guard let winner = peaks.first(where: { $0.magnitude == maximum }) else { throw .noPeak(side) }
        for competitor in peaks where competitor != winner {
            let product = UInt64(competitor.magnitude) * UInt64(policy.dominance)
            if product >= UInt64(winner.magnitude) {
                throw .ambiguousPeaks(side, winner: winner, competitor: competitor)
            }
        }
        return winner
    }

    private static func magnitudeRuns(_ samples: [Int32]) -> [ImpulsePeak] {
        var result: [ImpulsePeak] = []
        var start = 0
        var magnitude = samples[0].magnitude
        for index in 1...samples.count {
            if index < samples.count, samples[index].magnitude == magnitude { continue }
            result.append(ImpulsePeak(index: start, plateauLength: index - start, magnitude: magnitude))
            guard index < samples.count else { break }
            start = index
            magnitude = samples[index].magnitude
        }
        return result
    }

    private static func localPeaks(_ runs: [ImpulsePeak]) -> [ImpulsePeak] {
        runs.indices.compactMap { index in
            let current = runs[index]
            let exceedsPrevious = index == runs.startIndex || current.magnitude > runs[index - 1].magnitude
            let exceedsNext = index == runs.index(before: runs.endIndex)
                || current.magnitude > runs[index + 1].magnitude
            return exceedsPrevious && exceedsNext ? current : nil
        }
    }
}
