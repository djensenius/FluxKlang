import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RouteLatencyTests {
    @Test func equalPathsAndEverySlowestTieGetZeroAdded() throws {
        let equal = try Self.aligned([Self.path("path.b", frames: 80), Self.path("path.a", frames: 80)])
        let equalIDs = try Self.ids("path.a", "path.b")
        #expect(equal.targetFrames == 80)
        #expect(equal.entries.map(\.path) == equalIDs)
        #expect(equal.entries.map(\.addedFrames) == [0, 0])
        #expect(equal.slowestPaths == equalIDs)
        let slower = try Self.aligned([
            Self.path("path.a", frames: 40), Self.path("path.b", frames: 90), Self.path("path.c", frames: 90)
        ])
        let slowerIDs = try Self.ids("path.b", "path.c")
        #expect(slower.targetFrames == 90)
        #expect(slower.entries.map(\.addedFrames) == [50, 0, 0])
        #expect(slower.slowestPaths == slowerIDs)
    }

    @Test func oneMeasuredPathHasZeroAddedFramesAndZeroPairwiseBound() throws {
        let plan = try Self.aligned([Self.path("path.only", frames: Int64.max, uncertainty: Int64.max)])
        #expect(plan.targetFrames == Int64.max)
        #expect(plan.entries.map(\.addedFrames) == [0])
        #expect(plan.misalignment == .withinFrames(0))
    }

    @Test func homogeneousMeasuredPathsUseTheTwoLargestUncertainties() throws {
        let plan = try Self.aligned([
            Self.path("path.a", frames: 30, uncertainty: 1),
            Self.path("path.b", frames: 40, uncertainty: 8),
            Self.path("path.c", frames: 50, uncertainty: 4)
        ])
        #expect(plan.misalignment == .withinFrames(12))
        #expect(plan.entries.map(\.uncertaintyFrames) == [1, 8, 4])
        #expect(plan.entries.map(\.kind) == [.analogRoundTrip, .analogRoundTrip, .analogRoundTrip])
    }

    @Test func mixedMeasuredKindsAndMeasuredReportedPairRefuseInSortedOrder() throws {
        let measuredKinds = [
            try Self.path("path.a", frames: 10, .digitalCalibration),
            try Self.path("path.b", frames: 10, .analogRoundTrip)
        ]
        #expect(Self.unalignable(measuredKinds) == .mixedKinds([.analogRoundTrip, .digitalCalibration]))
        let measuredAndReported = [
            try Self.path("path.a", frames: 10, .reported),
            try Self.path("path.b", frames: 10, .analogRoundTrip)
        ]
        #expect(Self.unalignable(measuredAndReported) == .mixedKinds([.analogRoundTrip, .reported]))
    }

    @Test func homogeneousAllReportedPathsAlignWithUnstatedBound() throws {
        let plan = try Self.aligned([
            Self.path("path.a", frames: 30, .reported),
            Self.path("path.b", frames: 50, .reported)
        ])
        #expect(plan.targetFrames == 50)
        #expect(plan.entries.map(\.kind) == [.reported, .reported])
        #expect(plan.entries.map(\.uncertaintyFrames) == [nil, nil])
        #expect(plan.misalignment == .unstated)
    }

    @Test func oneUnknownPathRefusesAndListsAllUnknownPathsInOrder() throws {
        let known = try Self.path("path.known", frames: 10)
        let unknownZ = CompensationPath(id: try LatencyPathID("path.z"), current: try Setup().configuration(),
                                       latency: .unknown)
        let unknownA = CompensationPath(id: try LatencyPathID("path.a"), current: try Setup().configuration(),
                                       latency: .unknown)
        #expect(Self.unalignable([known, unknownZ]) == .unknownLatency(try Self.ids("path.z")))
        #expect(Self.unalignable([unknownZ, known, unknownA]) == .unknownLatency(try Self.ids("path.a", "path.z")))
    }

    @Test func staleCalibrationRefusesWithExactOrderedReasons() throws {
        let recorded = Setup()
        var current = recorded
        current.uid = "uid.other"
        current.input += 1
        let stale = try Self.path("path.stale", frames: 10, setup: recorded, current: current)
        #expect(Self.unalignable([stale])
            == .staleCalibration([StalePath(path: try LatencyPathID("path.stale"),
                                            reasons: [.deviceIdentity, .inputBuffer])]))
        let repaired = try Self.path("path.stale", frames: 10, setup: current, current: current)
        #expect(try Self.aligned([repaired]).targetFrames == 10)
    }

    @Test func sampleRateMismatchListsDistinctRatesAscending() throws {
        var fast = Setup()
        fast.rate = 96_000
        let paths = [
            try Self.path("path.fast", frames: 10, setup: fast),
            try Self.path("path.base", frames: 10)
        ]
        #expect(Self.unalignable(paths) == .sampleRateMismatch([48_000, 96_000]))
    }

    @Test func pathCountsAndDuplicateIDsHaveTypedRefusals() throws {
        #expect(Self.unalignable([]) == .noPaths)
        var maximum: [CompensationPath] = []
        for index in 0..<PathDelayCompensation.maximumPaths {
            maximum.append(try Self.path("path.\(index)", frames: 10))
        }
        #expect(try Self.aligned(maximum).entries.count == PathDelayCompensation.maximumPaths)
        maximum.append(try Self.path("path.64", frames: 10))
        #expect(Self.unalignable(maximum) == .tooManyPaths(count: PathDelayCompensation.maximumPaths + 1))

        let duplicate = [
            try Self.path("path.z", frames: 10), try Self.path("path.a", frames: 10),
            try Self.path("path.a", frames: 10)
        ]
        #expect(Self.unalignable(duplicate) == .duplicatePath(try LatencyPathID("path.a")))
    }

    @Test func misalignmentSumAcceptsMaximumAndRefusesOneBeyond() throws {
        let atLimit = try Self.aligned([
            Self.path("path.a", frames: 0, uncertainty: Int64.max - 1),
            Self.path("path.b", frames: 1, uncertainty: 1)
        ])
        #expect(atLimit.misalignment == .withinFrames(Int64.max))
        let beyondLimit = [
            try Self.path("path.a", frames: 0, uncertainty: Int64.max),
            try Self.path("path.b", frames: 1, uncertainty: 1)
        ]
        #expect(Self.unalignable(beyondLimit) == .misalignmentBoundOverflow)
    }

    @Test func maximumLatencyProducesExactNonOverflowingDifference() throws {
        let plan = try Self.aligned([
            Self.path("path.zero", frames: 0), Self.path("path.max", frames: Int64.max)
        ])
        #expect(plan.targetFrames == Int64.max)
        #expect(plan.entries.map(\.addedFrames) == [0, Int64.max])
    }

    @Test func allPermutationsProduceIdenticalOrderedPlan() throws {
        let paths = [
            try Self.path("path.d", frames: 70, uncertainty: 4),
            try Self.path("path.b", frames: 20, uncertainty: 2),
            try Self.path("path.c", frames: 50, uncertainty: 3),
            try Self.path("path.a", frames: 10, uncertainty: 1)
        ]
        let expected = try Self.aligned(paths)
        for first in paths.indices {
            for second in paths.indices where second != first {
                for third in paths.indices where third != first && third != second {
                    let fourth = try #require(paths.indices.first { $0 != first && $0 != second && $0 != third })
                    let permutation = [paths[first], paths[second], paths[third], paths[fourth]]
                    #expect(try Self.aligned(permutation) == expected)
                }
            }
        }
    }

    @Test func refusalPrecedenceIsStructuralThenEvidenceThenComparabilityThenBound() throws {
        let validMeasuredPath = try Self.path("path.a", frames: 0)
        var staleSetup = Setup()
        staleSetup.uid = "uid.changed"
        let stale = try Self.path("path.stale", frames: 1, current: staleSetup)
        let unknown = CompensationPath(id: try LatencyPathID("path.unknown"), current: try Setup().configuration(),
                                       latency: .unknown)
        #expect(Self.unalignable([unknown, stale]) == .unknownLatency(try Self.ids("path.unknown")))
        #expect(Self.unalignable([stale, try Self.path("path.mixed", frames: 2, .reported)])
            == .staleCalibration([StalePath(path: try LatencyPathID("path.stale"),
                                            reasons: [.deviceIdentity])]))

        var otherRate = Setup()
        otherRate.rate = 44_100
        let rateMismatch = try Self.path("path.rate", frames: 3, setup: otherRate)
        let mixed = try Self.path("path.mixed", frames: 4, .reported)
        #expect(Self.unalignable([validMeasuredPath, rateMismatch, mixed])
            == .sampleRateMismatch([44_100, 48_000]))
        let mixedAndOverflow = [
            try Self.path("path.a", frames: 0, uncertainty: Int64.max),
            try Self.path("path.b", frames: 1, .digitalCalibration, uncertainty: Int64.max)
        ]
        #expect(Self.unalignable(mixedAndOverflow) == .mixedKinds([.analogRoundTrip, .digitalCalibration]))
        let boundOverflow = [
            try Self.path("path.a", frames: 0, uncertainty: Int64.max),
            try Self.path("path.b", frames: 1, uncertainty: 1)
        ]
        #expect(Self.unalignable(boundOverflow) == .misalignmentBoundOverflow)
    }

    @Test func alignmentRefusalsRepeatAndLeaveInputValuesUnchanged() throws {
        let paths = [
            try Self.path("path.a", frames: 10, uncertainty: Int64.max),
            try Self.path("path.b", frames: 20, uncertainty: 1)
        ]
        let before = paths
        let first = PathDelayCompensation.align(paths)
        let second = PathDelayCompensation.align(paths)
        #expect(first == .unalignable(.misalignmentBoundOverflow))
        #expect(first == second)
        #expect(paths == before)
    }

    @Test func impulseFixturesCanFlowThroughRecordsIntoOnePlan() throws {
        let policy = try ImpulsePolicy.make(minimumPeak: 1, dominance: 2)
        let estimate = try ImpulseAlignment.estimate(stimulus: [0, 5, 0, 0], response: [0, 0, 0, 5],
                                                      policy: policy)
        let measured = try LatencyMeasurement.softwareImpulseDelay(from: estimate)
        let configuration = try Setup().configuration()
        let first = try CalibrationRecord.make(measurement: measured, producer: "fixture.a",
                                               configuration: configuration)
        let secondMeasurement = try Self.measurement(.softwareImpulseDelay, frames: 4, uncertainty: 1)
        let second = try CalibrationRecord.make(measurement: secondMeasurement, producer: "fixture.b",
                                                configuration: configuration)
        let plan = try Self.aligned([
            CompensationPath(id: try LatencyPathID("path.a"), current: configuration, latency: .recorded(first)),
            CompensationPath(id: try LatencyPathID("path.b"), current: configuration, latency: .recorded(second))
        ])
        #expect(plan.entries.map(\.latencyFrames) == [2, 4])
        #expect(plan.entries.map(\.addedFrames) == [2, 0])
        #expect(plan.entries.map(\.kind) == [.softwareImpulseDelay, .softwareImpulseDelay])
    }
}
