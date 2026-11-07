import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Run record validation: sample and recovery limits, non-positive values and refusal order.
extension RunStatisticsTests {
    @Test func recordKeepsCaptureOrderAndEveryMeasuredField() throws {
        let run = try Self.record([30, 10, 20], deadline: 25, dropouts: 2, recoveries: [7, 3], experiment: "exp.1")
        #expect(run.renderNanoseconds == [30, 10, 20])
        #expect(run.deadlineNanoseconds == 25)
        #expect(run.dropouts == 2)
        #expect(run.recoveryNanoseconds == [7, 3])
        #expect(run.experiment?.rawValue == "exp.1")
        #expect(run.variables == (try Self.variables()))
        #expect(try Self.record([1]).experiment == nil)
    }

    @Test func sampleCountAcceptsOneAndTheMaximumAndRefusesNoneAndOneBeyond() throws {
        #expect(try Self.record([1]).renderNanoseconds.count == 1)
        let limit = RunLimits.maximumSamples
        #expect(limit == 100_000)
        #expect(try Self.record(Array(repeating: 1, count: limit)).renderNanoseconds.count == limit)
        #expect(throws: RunRefusal.noSamples) { try Self.record([]) }
        #expect(throws: RunRefusal.tooManySamples(count: limit + 1)) {
            try Self.record(Array(repeating: 1, count: limit + 1))
        }
    }

    @Test func recoveryCountAcceptsTheMaximumAndRefusesOneBeyond() throws {
        let limit = RunLimits.maximumRecoveries
        #expect(limit == 1_024)
        #expect(try Self.record([1], recoveries: Array(repeating: 5, count: limit)).recoveryNanoseconds.count == limit)
        #expect(try Self.record([1], recoveries: []).recoveryNanoseconds.isEmpty)
        #expect(throws: RunRefusal.tooManyRecoveries(count: limit + 1)) {
            try Self.record([1], recoveries: Array(repeating: 5, count: limit + 1))
        }
    }

    @Test func durationsMustBeAtLeastOneNanosecondAndReportTheFirstOffender() throws {
        #expect(try Self.record([1], deadline: 1, recoveries: [1]).deadlineNanoseconds == 1)
        #expect(throws: RunRefusal.nonPositiveRenderDuration(index: 0, nanoseconds: 0)) { try Self.record([0, 5]) }
        #expect(throws: RunRefusal.nonPositiveRenderDuration(index: 2, nanoseconds: -4)) {
            try Self.record([5, 6, -4, 0])
        }
        #expect(throws: RunRefusal.nonPositiveDeadline(0)) { try Self.record([5], deadline: 0) }
        #expect(throws: RunRefusal.nonPositiveDeadline(-1)) { try Self.record([5], deadline: -1) }
        #expect(throws: RunRefusal.nonPositiveRecovery(index: 1, nanoseconds: 0)) {
            try Self.record([5], recoveries: [3, 0, -2])
        }
        #expect(throws: RunRefusal.nonPositiveRecovery(index: 0, nanoseconds: -9)) {
            try Self.record([5], recoveries: [-9])
        }
    }

    @Test func dropoutsAcceptZeroAndIntMaximumAndRefuseNegative() throws {
        #expect(try Self.record([1], dropouts: 0).dropouts == 0)
        #expect(try Self.record([1], dropouts: Int.max).dropouts == Int.max)
        #expect(throws: RunRefusal.negativeDropouts(-1)) { try Self.record([1], dropouts: -1) }
    }

    @Test func experimentReferenceIsOptionalOpaqueAndValidated() throws {
        #expect(try Self.record([1], experiment: String(repeating: "e", count: 128)).experiment != nil)
        #expect(throws: RunRefusal.invalidID(.experiment, bytes: 0)) { try Self.record([1], experiment: "") }
        #expect(throws: RunRefusal.invalidID(.experiment, bytes: 7)) { try Self.record([1], experiment: "bad id!") }
    }

    @Test func recordRefusalsFollowTheDocumentedOrder() {
        let bad = Self.measurements([], deadline: 0, dropouts: -1, recoveries: [0])
        #expect(throws: RunRefusal.invalidID(.experiment, bytes: 0)) { try Self.record(bad, experiment: "") }
        #expect(throws: RunRefusal.noSamples) { try Self.record(bad) }
        let renders = Self.measurements([4, 0], deadline: 0, dropouts: -1, recoveries: [0])
        #expect(throws: RunRefusal.nonPositiveRenderDuration(index: 1, nanoseconds: 0)) { try Self.record(renders) }
        let deadline = Self.measurements([4], deadline: 0, dropouts: -1, recoveries: [0])
        #expect(throws: RunRefusal.nonPositiveDeadline(0)) { try Self.record(deadline) }
        let dropouts = Self.measurements([4], dropouts: -1, recoveries: [0])
        #expect(throws: RunRefusal.negativeDropouts(-1)) { try Self.record(dropouts) }
        let many = Self.measurements([4], recoveries: Array(repeating: 0, count: RunLimits.maximumRecoveries + 1))
        #expect(throws: RunRefusal.tooManyRecoveries(count: RunLimits.maximumRecoveries + 1)) {
            try Self.record(many)
        }
        let recovery = Self.measurements([4], recoveries: [0])
        #expect(throws: RunRefusal.nonPositiveRecovery(index: 0, nanoseconds: 0)) { try Self.record(recovery) }
    }

    @Test func tooManySamplesIsRefusedBeforeEveryLaterDefect() {
        let count = RunLimits.maximumSamples + 1
        let defects = Self.measurements(Array(repeating: 0, count: count), deadline: 0, dropouts: -1,
                                        recoveries: Array(repeating: 0, count: RunLimits.maximumRecoveries + 1))
        #expect(throws: RunRefusal.tooManySamples(count: count)) { try Self.record(defects) }
    }

    @Test func recordsAreValuesWithoutAnyQualityOrdering() throws {
        let first = try Self.record([5, 6])
        let same = try Self.record([5, 6])
        let other = try Self.record([5, 7])
        #expect(first == same)
        #expect(first != other)
        #expect(Set([first, same, other]).count == 2)
    }
}

extension RunStatisticsTests {
    static func record(_ measurements: RunMeasurements, experiment: String? = nil) throws -> RunRecord {
        try RunRecord.make(variables: variables(), experiment: experiment, measurements: measurements)
    }
}
