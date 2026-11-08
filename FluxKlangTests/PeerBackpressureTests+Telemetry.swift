import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private func window(_ capacity: Int, _ samples: [Int]) throws -> PeerTelemetryWindow {
    var window = try PeerTelemetryWindow.make(capacity: capacity)
    for sample in samples { window.record(sample) }
    return window
}

extension PeerBackpressureTests {
    @Test func telemetrySnapshotOfAnEmptyWindowHasNoMinimumOrMaximum() throws {
        let empty = try window(4, [])
        #expect(empty.snapshot() == PeerTelemetrySnapshot(capacity: 4, count: 0, min: nil, max: nil, sum: 0,
                                                          sumOverflowed: false, droppedSamples: 0))
    }

    @Test func telemetrySnapshotSummarisesSamplesBelowCapacityExactly() throws {
        let partial = try window(8, [5, -2, 9, 0])
        #expect(partial.snapshot() == PeerTelemetrySnapshot(capacity: 8, count: 4, min: -2, max: 9, sum: 12,
                                                            sumOverflowed: false, droppedSamples: 0))
    }

    @Test func telemetryCapacityOneKeepsOnlyTheNewestSampleAndCountsEachReplacement() throws {
        var single = try window(1, [5])
        #expect(single.snapshot().min == 5)
        #expect(single.snapshot().droppedSamples == 0)
        single.record(7)
        single.record(3)
        #expect(single.snapshot() == PeerTelemetrySnapshot(capacity: 1, count: 1, min: 3, max: 3, sum: 3,
                                                           sumOverflowed: false, droppedSamples: 2))
    }

    @Test func telemetryDropsNothingAtCapacityAndTheOldestOnTheNextSample() throws {
        var full = try window(3, [1, 5, 9])
        #expect(full.snapshot() == PeerTelemetrySnapshot(capacity: 3, count: 3, min: 1, max: 9, sum: 15,
                                                         sumOverflowed: false, droppedSamples: 0))
        full.record(3)
        #expect(full.snapshot() == PeerTelemetrySnapshot(capacity: 3, count: 3, min: 3, max: 9, sum: 17,
                                                         sumOverflowed: false, droppedSamples: 1))
        full.record(2)
        #expect(full.snapshot() == PeerTelemetrySnapshot(capacity: 3, count: 3, min: 2, max: 9, sum: 14,
                                                         sumOverflowed: false, droppedSamples: 2))
    }

    @Test func telemetryReplacesTheOldestNotTheNewestWhenFull() throws {
        let rolled = try window(2, [100, 1, 2])
        #expect(rolled.snapshot().max == 2)
        #expect(rolled.snapshot().min == 1)
        #expect(rolled.snapshot().sum == 3)
    }

    @Test func telemetryKeepsExactlyCapacitySamplesAfterManyRecords() throws {
        var wide = try PeerTelemetryWindow.make(capacity: 1_024)
        for sample in 0..<3_000 { wide.record(sample) }
        #expect(wide.snapshot() == PeerTelemetrySnapshot(capacity: 1_024, count: 1_024, min: 1_976, max: 2_999,
                                                         sum: 2_547_200, sumOverflowed: false, droppedSamples: 1_976))
        #expect(wide.count == 1_024)
    }

    @Test func telemetryMinimumAndMaximumHandleTheExtremesWithoutOverflow() throws {
        let extremes = try window(4, [0, Int.max, Int.min, 7])
        #expect(extremes.snapshot() == PeerTelemetrySnapshot(capacity: 4, count: 4, min: Int.min, max: Int.max,
                                                             sum: 6, sumOverflowed: false, droppedSamples: 0))
    }

    @Test func telemetrySumSaturatesUpwardAndFlagsOverflow() throws {
        let high = try window(3, [Int.max, 1, 5])
        #expect(high.snapshot() == PeerTelemetrySnapshot(capacity: 3, count: 3, min: 1, max: Int.max, sum: Int.max,
                                                         sumOverflowed: true, droppedSamples: 0))
    }

    @Test func telemetrySumSaturatesDownwardAndFlagsOverflow() throws {
        let low = try window(2, [Int.min, -1])
        #expect(low.snapshot() == PeerTelemetrySnapshot(capacity: 2, count: 2, min: Int.min, max: -1, sum: Int.min,
                                                        sumOverflowed: true, droppedSamples: 0))
    }

    @Test func telemetryOverflowFlagClearsOnceTheOverflowingSamplesLeaveTheWindow() throws {
        var rolling = try window(2, [Int.max, 1])
        #expect(rolling.snapshot().sumOverflowed)
        rolling.record(0)
        rolling.record(0)
        #expect(rolling.snapshot() == PeerTelemetrySnapshot(capacity: 2, count: 2, min: 0, max: 0, sum: 0,
                                                            sumOverflowed: false, droppedSamples: 2))
    }

    @Test func telemetrySumAtExactlyIntMaxDoesNotFlagOverflow() throws {
        let exact = try window(2, [Int.max - 1, 1])
        #expect(exact.snapshot().sum == Int.max)
        #expect(!exact.snapshot().sumOverflowed)
    }

    @Test func telemetrySnapshotDoesNotChangeTheWindowAndSameRecordsGiveEqualWindows() throws {
        let samples = [4, -8, 15, 16, -23, 42, 3]
        var first = try window(4, samples)
        let second = try window(4, samples)
        let before = first
        #expect(first.snapshot() == second.snapshot())
        #expect(first == before)
        #expect(first == second)
        first.record(1)
        #expect(first != second)
    }
}
