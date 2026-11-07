import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct AmbiguousPeakExpectations {
    let winnerIndex: Int
    let competitorIndex: Int
    let winnerMagnitude: UInt32
    let competitorMagnitude: UInt32
}

extension RouteLatencyTests {
    fileprivate static func expectAmbiguous(_ stimulus: [Int32], policy: ImpulsePolicy,
                                            expected: AmbiguousPeakExpectations) throws {
        do {
            _ = try ImpulseAlignment.estimate(stimulus: stimulus, response: [0, 8, 0], policy: policy)
            Issue.record("expected ambiguous impulse peaks")
        } catch let refusal {
            guard case .ambiguousPeaks(.stimulus, let winner, let competitor) = refusal else {
                Issue.record("unexpected impulse refusal: \(refusal)")
                return
            }
            #expect(winner.index == expected.winnerIndex)
            #expect(winner.magnitude == expected.winnerMagnitude)
            #expect(competitor.index == expected.competitorIndex)
            #expect(competitor.magnitude == expected.competitorMagnitude)
        }
    }

    @Test func impulseOffsetsAreSignedResponseMinusStimulus() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        let positive = try ImpulseAlignment.estimate(stimulus: [0, 4, 0, 0], response: [0, 0, 0, 4],
                                                      policy: policy)
        let negative = try ImpulseAlignment.estimate(stimulus: [0, 0, 4], response: [4, 0, 0],
                                                      policy: policy)
        let zero = try ImpulseAlignment.estimate(stimulus: [0, 4, 0], response: [0, 3, 0], policy: policy)
        #expect(positive.offsetFrames == 2)
        #expect(negative.offsetFrames == -2)
        #expect(zero.offsetFrames == 0)
    }

    @Test func plateauTiesChooseEarliestIndicesAndReportBothSpans() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        let estimate = try ImpulseAlignment.estimate(stimulus: [0, 5, 5, 0], response: [0, 0, 3, 3, 0],
                                                      policy: policy)
        #expect(estimate.stimulus.index == 1)
        #expect(estimate.response.index == 2)
        #expect(estimate.offsetFrames == 1)
        #expect(estimate.uncertaintyFrames == 2)
    }

    @Test func polarityIsIgnoredAndInt32MinimumHasMagnitudeTwoToThe31() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        let estimate = try ImpulseAlignment.estimate(stimulus: [0, Int32.min, 0],
                                                      response: [0, Int32.min, 0], policy: policy)
        #expect(estimate.stimulus.magnitude == 2_147_483_648)
        #expect(estimate.response.magnitude == 2_147_483_648)
        #expect(estimate.offsetFrames == 0)
        let reversedPolarity = try ImpulseAlignment.estimate(stimulus: [0, -7, 0], response: [0, 7, 0],
                                                              policy: policy)
        #expect(reversedPolarity.stimulus.magnitude == reversedPolarity.response.magnitude)
    }

    @Test func emptySilenceAndNoPeakRefusalsIdentifyTheirSide() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        #expect(throws: ImpulseRefusal.emptySequence(.stimulus)) {
            try ImpulseAlignment.estimate(stimulus: [], response: [0, 2, 0], policy: policy)
        }
        #expect(throws: ImpulseRefusal.emptySequence(.response)) {
            try ImpulseAlignment.estimate(stimulus: [0, 2, 0], response: [], policy: policy)
        }
        #expect(throws: ImpulseRefusal.silence(.stimulus)) {
            try ImpulseAlignment.estimate(stimulus: [0, 0], response: [0, 2, 0], policy: policy)
        }
        #expect(throws: ImpulseRefusal.silence(.response)) {
            try ImpulseAlignment.estimate(stimulus: [0, 2, 0], response: [0, 0], policy: policy)
        }
        #expect(throws: ImpulseRefusal.noPeak(.stimulus)) {
            try ImpulseAlignment.estimate(stimulus: [0, 1, 0], response: [0, 2, 0],
                                          policy: try ImpulsePolicy.make(minimumPeak: 2, dominance: 2))
        }
        #expect(throws: ImpulseRefusal.noPeak(.stimulus)) {
            try ImpulseAlignment.estimate(stimulus: [5], response: [0, 2, 0], policy: policy)
        }
        #expect(throws: ImpulseRefusal.noPeak(.stimulus)) {
            try ImpulseAlignment.estimate(stimulus: [5, 5, 5], response: [0, 2, 0], policy: policy)
        }
    }

    @Test func policyMinimumAndAmbiguityRatiosUseExactBoundaries() throws {
        let accepted = try ImpulsePolicy.make(minimumPeak: 1, dominance: 1)
        let atMinimum = try ImpulseAlignment.estimate(stimulus: [0, 1, 0], response: [0, 1, 0],
                                                       policy: accepted)
        #expect(atMinimum.stimulus.magnitude == 1)
        #expect(throws: ImpulseRefusal.noPeak(.stimulus)) {
            try ImpulseAlignment.estimate(stimulus: [0, 1, 0], response: [0, 1, 0],
                                          policy: try ImpulsePolicy.make(minimumPeak: 2, dominance: 1))
        }

        // c*d is peak−1 (unambiguous), equal to peak, then peak+1 (ambiguous).
        let below = try ImpulseAlignment.estimate(stimulus: [0, 2, 0, 7, 0], response: [0, 8, 0],
                                                   policy: try ImpulsePolicy.make(minimumPeak: 1, dominance: 3))
        #expect(below.stimulus.magnitude == 7)
        try Self.expectAmbiguous([0, 7, 0, 7, 0],
                                 policy: ImpulsePolicy.make(minimumPeak: 1, dominance: 1),
                                 expected: AmbiguousPeakExpectations(
                                    winnerIndex: 1, competitorIndex: 3,
                                    winnerMagnitude: 7, competitorMagnitude: 7
                                 ))
        try Self.expectAmbiguous([0, 2, 0, 7, 0],
                                 policy: ImpulsePolicy.make(minimumPeak: 1, dominance: 4),
                                 expected: AmbiguousPeakExpectations(
                                    winnerIndex: 3, competitorIndex: 1,
                                    winnerMagnitude: 7, competitorMagnitude: 2
                                 ))
    }

    @Test func widenedUInt64AmbiguityProductHandlesExtremeMagnitudeAndRatio() throws {
        let maxMagnitude = Int32.min.magnitude
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 4)
        try Self.expectAmbiguous([0, 1_073_741_824, 0, Int32.min, 0], policy: policy,
                                 expected: AmbiguousPeakExpectations(
                                    winnerIndex: 3, competitorIndex: 1, winnerMagnitude: maxMagnitude,
                                    competitorMagnitude: 1_073_741_824
                                 ))
        #expect(try ImpulsePolicy.make(minimumPeak: 1, dominance: UInt32.max).dominance == UInt32.max)
    }

    @Test func equalSeparatedPeaksAreAmbiguousButPulseShouldersAreNot() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        try Self.expectAmbiguous([0, 5, 0, 1, 0, 5, 0], policy: policy,
                                 expected: AmbiguousPeakExpectations(
                                    winnerIndex: 1, competitorIndex: 5, winnerMagnitude: 5, competitorMagnitude: 5
                                 ))
        let shoulders = try ImpulseAlignment.estimate(stimulus: [0, 2, 5, 2, 0], response: [0, 4, 0],
                                                       policy: policy)
        #expect(shoulders.stimulus.index == 2)
    }

    @Test func maximumFixtureLengthAcceptsLastIndexAndRejectsOneBeyond() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        var maximum = Array(repeating: Int32(0), count: ImpulseAlignment.maximumSamples)
        maximum[maximum.count - 1] = 4
        let estimate = try ImpulseAlignment.estimate(stimulus: maximum, response: maximum, policy: policy)
        #expect(estimate.stimulus.index == ImpulseAlignment.maximumSamples - 1)
        var oversized = maximum
        oversized.append(0)
        #expect(throws: ImpulseRefusal.sequenceTooLong(.stimulus, count: ImpulseAlignment.maximumSamples + 1)) {
            try ImpulseAlignment.estimate(stimulus: oversized, response: [], policy: policy)
        }
        #expect(throws: ImpulseRefusal.sequenceTooLong(.response, count: ImpulseAlignment.maximumSamples + 1)) {
            try ImpulseAlignment.estimate(stimulus: maximum, response: oversized, policy: policy)
        }
    }

    @Test func stimulusRefusalPrecedesResponseAndResultsRepeatExactly() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        let stimulus: [Int32] = [0, 5, 0]
        let response: [Int32] = [0, 4, 0]
        let first = try ImpulseAlignment.estimate(stimulus: stimulus, response: response, policy: policy)
        let second = try ImpulseAlignment.estimate(stimulus: stimulus, response: response, policy: policy)
        #expect(first == second)
        #expect(stimulus == [0, 5, 0] && response == [0, 4, 0])
        #expect(throws: ImpulseRefusal.silence(.stimulus)) {
            try ImpulseAlignment.estimate(stimulus: [0, 0], response: [], policy: policy)
        }
    }

    @Test func invalidImpulsePoliciesRefuseZeroThresholds() {
        #expect(throws: ImpulseRefusal.invalidMinimumPeak) { try ImpulsePolicy.make(minimumPeak: 0, dominance: 1) }
        #expect(throws: ImpulseRefusal.invalidDominance) { try ImpulsePolicy.make(minimumPeak: 1, dominance: 0) }
    }

    @Test func softwareImpulseMeasurementKeepsOffsetAndUncertaintyAndRejectsNegative() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        let estimate = try ImpulseAlignment.estimate(stimulus: [0, 5, 5, 0],
                                                      response: [0, 0, 4, 4, 0], policy: policy)
        let measurement = try LatencyMeasurement.softwareImpulseDelay(from: estimate)
        #expect(measurement.kind == .softwareImpulseDelay)
        #expect(measurement.frames == 1)
        #expect(measurement.uncertaintyFrames == 2)
        let negative = try ImpulseAlignment.estimate(stimulus: [0, 0, 5], response: [5, 0, 0], policy: policy)
        #expect(throws: LatencyRefusal.negativeFrames(-2)) {
            try LatencyMeasurement.softwareImpulseDelay(from: negative)
        }
    }
}
