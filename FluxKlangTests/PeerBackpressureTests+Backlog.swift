import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = PeerBackpressureFixture
private typealias Refusal = PeerBackpressureRefusal

private func record(_ backlog: inout PeerOutboundBacklog, _ sequence: Int, changes: Int) throws {
    try backlog.record(session: try Fixture.session(), sequence: try Fixture.sequence(sequence),
                       changeCount: changes)
}

private func recordRefusal(_ backlog: inout PeerOutboundBacklog, _ sequence: Int, changes: Int,
                           session: PeerSyncSession? = nil) throws -> Refusal? {
    let owner = try session ?? Fixture.session()
    let found = try Fixture.sequence(sequence)
    return Fixture.refusal { () throws(Refusal) in
        try backlog.record(session: owner, sequence: found, changeCount: changes)
    }
}

/// A backlog holding sequences 1...4 with 1, 2, 3 and 4 changes.
private func filled(deltas: Int = 8, changes: Int = 40) throws -> PeerOutboundBacklog {
    var backlog = try Fixture.backlog(deltas: deltas, changes: changes)
    for index in 1...4 { try record(&backlog, index, changes: index) }
    return backlog
}

extension PeerBackpressureTests {
    // MARK: record

    @Test func recordCountsUpdatesAndRemovalsOfEachContiguousDelta() throws {
        var backlog = try Fixture.backlog()
        try backlog.record(delta: try Fixture.delta(1, updates: 2, removals: 3))
        try backlog.record(delta: try Fixture.delta(2, updates: 1))
        #expect(backlog.pendingDeltas == 2)
        #expect(backlog.pendingChanges == 6)
        #expect(backlog.recordedThrough == (try Fixture.sequence(2)))
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(0)))
        #expect(!backlog.requiresSnapshot)
    }

    @Test func recordRefusesADeltaOfAnotherConnectionOrHostEpoch() throws {
        var backlog = try filled()
        let before = backlog
        let foreignConnection = try Fixture.delta(5, session: try Fixture.session(connection: 2))
        let otherConnection = Fixture.refusal { () throws(Refusal) in try backlog.record(delta: foreignConnection) }
        #expect(otherConnection == .sessionMismatch)
        let foreignHost = try Fixture.delta(5, session: try Fixture.session(host: 2))
        let otherHost = Fixture.refusal { () throws(Refusal) in try backlog.record(delta: foreignHost) }
        #expect(otherHost == .sessionMismatch)
        #expect(backlog == before)
        try backlog.record(delta: try Fixture.delta(5))
        #expect(backlog.pendingDeltas == 5)
    }

    @Test func recordRefusesGapDuplicateAndOldSequencesWithExpectedAndFound() throws {
        var backlog = try filled()
        let before = backlog
        let gap = try recordRefusal(&backlog, 7, changes: 1)
        #expect(gap == .sequenceGap(expected: try Fixture.sequence(5), found: try Fixture.sequence(7)))
        let duplicate = try recordRefusal(&backlog, 4, changes: 1)
        #expect(duplicate == .sequenceGap(expected: try Fixture.sequence(5), found: try Fixture.sequence(4)))
        let zero = try recordRefusal(&backlog, 0, changes: 1)
        #expect(zero == .sequenceGap(expected: try Fixture.sequence(5), found: try Fixture.sequence(0)))
        #expect(backlog == before)
    }

    @Test func recordAcceptsTheDeltaLimitAndRefusesOneMore() throws {
        var backlog = try Fixture.backlog(deltas: 3, changes: 100)
        for index in 1...3 { try record(&backlog, index, changes: 1) }
        #expect(backlog.pendingDeltas == 3)
        let before = backlog
        let result = try recordRefusal(&backlog, 4, changes: 1)
        #expect(result == .backlogFull)
        #expect(backlog == before)
    }

    @Test func recordAcceptsTheChangeLimitAndRefusesOneMore() throws {
        var backlog = try Fixture.backlog(deltas: 8, changes: 10)
        try record(&backlog, 1, changes: 4)
        try record(&backlog, 2, changes: 6)
        #expect(backlog.pendingChanges == 10)
        let before = backlog
        let result = try recordRefusal(&backlog, 3, changes: 1)
        #expect(result == .backlogFull)
        #expect(backlog == before)
        var single = try Fixture.backlog(deltas: 8, changes: 10)
        let over = try recordRefusal(&single, 1, changes: 11)
        #expect(over == .backlogFull)
        #expect(single.pendingChanges == 0)
        try record(&single, 1, changes: 10)
        #expect(single.pendingChanges == 10)
    }

    @Test func recordAcceptsADeltaWithNoChangesAndCountsItAsADelta() throws {
        var backlog = try Fixture.backlog(deltas: 2, changes: 1)
        try backlog.record(delta: try Fixture.delta(1, updates: 0))
        #expect(backlog.pendingDeltas == 1)
        #expect(backlog.pendingChanges == 0)
    }

    @Test func recordAcceptsFourThousandNinetySixDeltasAndRefusesTheNext() throws {
        var backlog = try Fixture.backlog(deltas: 4_096, changes: 65_536)
        for index in 1...4_096 { try record(&backlog, index, changes: 1) }
        #expect(backlog.pendingDeltas == 4_096)
        #expect(try recordRefusal(&backlog, 4_097, changes: 1) == .backlogFull)
        #expect(backlog.pendingChanges == 4_096)
    }

    @Test func recordAcceptsSixtyFiveThousandFiveHundredThirtySixChangesAndRefusesOneMore() throws {
        var backlog = try Fixture.backlog(deltas: 4_096, changes: 65_536)
        try record(&backlog, 1, changes: 65_535)
        #expect(try recordRefusal(&backlog, 2, changes: 2) == .backlogFull)
        try record(&backlog, 2, changes: 1)
        #expect(backlog.pendingChanges == 65_536)
    }

    @Test func recordRefusesAChangeCountNearIntMaxAsOverflowWithoutWrapping() throws {
        var backlog = try filled()
        let before = backlog
        let near = try recordRefusal(&backlog, 5, changes: Int.max)
        #expect(near == .overflow)
        let nearMinusOne = try recordRefusal(&backlog, 5, changes: Int.max - 9)
        #expect(nearMinusOne == .overflow)
        #expect(backlog == before)
        var empty = try Fixture.backlog(deltas: 8, changes: 10)
        #expect(try recordRefusal(&empty, 1, changes: Int.max) == .backlogFull)
    }

    @Test func recordRefusesANegativeChangeCountAsOverflow() throws {
        var backlog = try filled()
        let before = backlog
        #expect(try recordRefusal(&backlog, 5, changes: -1) == .overflow)
        #expect(backlog == before)
    }

    // MARK: record order (every fixture holds both defects; each alone is shown too)

    @Test func recordReportsSessionMismatchBeforeSequenceGap() throws {
        var backlog = try filled()
        let before = backlog
        let other = try Fixture.session(connection: 2)
        let both = try recordRefusal(&backlog, 9, changes: 1, session: other)
        #expect(both == .sessionMismatch)
        let gapAlone = try recordRefusal(&backlog, 9, changes: 1)
        #expect(gapAlone == .sequenceGap(expected: try Fixture.sequence(5), found: try Fixture.sequence(9)))
        #expect(backlog == before)
    }

    @Test func recordReportsSequenceGapBeforeBacklogFull() throws {
        var backlog = try filled(deltas: 4, changes: 10)
        let before = backlog
        let both = try recordRefusal(&backlog, 9, changes: 1)
        #expect(both == .sequenceGap(expected: try Fixture.sequence(5), found: try Fixture.sequence(9)))
        let fullAlone = try recordRefusal(&backlog, 5, changes: 1)
        #expect(fullAlone == .backlogFull)
        #expect(backlog == before)
    }

    @Test func recordReportsBacklogFullBeforeANegativeChangeCount() throws {
        var backlog = try filled(deltas: 4, changes: 40)
        let before = backlog
        #expect(try recordRefusal(&backlog, 5, changes: -3) == .backlogFull)
        var roomy = try filled(deltas: 8, changes: 40)
        #expect(try recordRefusal(&roomy, 5, changes: -3) == .overflow)
        #expect(backlog == before)
    }

    @Test func recordReportsSessionMismatchAndThenOverflowWhenSequencesAreExhausted() throws {
        var backlog = try Fixture.backlog(from: PeerSequence.maximumValue)
        let before = backlog
        let other = try Fixture.session(connection: 2)
        #expect(try recordRefusal(&backlog, 5, changes: 1, session: other) == .sessionMismatch)
        #expect(try recordRefusal(&backlog, 5, changes: 1) == .overflow)
        #expect(try recordRefusal(&backlog, PeerSequence.maximumValue, changes: 1) == .overflow)
        #expect(backlog == before)
    }

    // MARK: acknowledge

    @Test func acknowledgeDropsThroughTheSequenceAndReturnsHowManyDeltas() throws {
        var backlog = try filled()
        #expect(backlog.pendingChanges == 10)
        let firstDrop = backlog.acknowledge(through: try Fixture.sequence(2))
        #expect(firstDrop == 2)
        #expect(backlog.pendingDeltas == 2)
        #expect(backlog.pendingChanges == 7)
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(2)))
        #expect(backlog.recordedThrough == (try Fixture.sequence(4)))
        let secondDrop = backlog.acknowledge(through: try Fixture.sequence(4))
        #expect(secondDrop == 2)
        #expect(backlog.pendingDeltas == 0)
        #expect(backlog.pendingChanges == 0)
    }

    @Test func acknowledgeIsIdempotent() throws {
        var backlog = try filled()
        backlog.acknowledge(through: try Fixture.sequence(3))
        let once = backlog
        let repeated = backlog.acknowledge(through: try Fixture.sequence(3))
        #expect(repeated == 0)
        #expect(backlog == once)
    }

    @Test func acknowledgeIgnoresValuesBelowTheFloor() throws {
        var backlog = try filled()
        backlog.acknowledge(through: try Fixture.sequence(3))
        let before = backlog
        let belowFloor = backlog.acknowledge(through: try Fixture.sequence(1))
        let atOrigin = backlog.acknowledge(through: try Fixture.sequence(0))
        #expect(belowFloor == 0)
        #expect(atOrigin == 0)
        #expect(backlog == before)
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(3)))
    }

    @Test func acknowledgeIgnoresValuesAboveTheNewestRecorded() throws {
        var backlog = try filled()
        let before = backlog
        let justAbove = backlog.acknowledge(through: try Fixture.sequence(5))
        let farAbove = backlog.acknowledge(through: try Fixture.sequence(PeerSequence.maximumValue))
        #expect(justAbove == 0)
        #expect(farAbove == 0)
        #expect(backlog == before)
    }

    @Test func acknowledgeOutOfOrderEndsInTheSameStateAsInOrder() throws {
        var ascending = try filled()
        ascending.acknowledge(through: try Fixture.sequence(2))
        ascending.acknowledge(through: try Fixture.sequence(3))
        var descending = try filled()
        descending.acknowledge(through: try Fixture.sequence(3))
        descending.acknowledge(through: try Fixture.sequence(2))
        var direct = try filled()
        direct.acknowledge(through: try Fixture.sequence(3))
        #expect(ascending == descending)
        #expect(descending == direct)
        #expect(direct.pendingChanges == 4)
    }

    @Test func recordAndAcknowledgeGiveTheSameValueInEitherOrderOnDisjointRanges() throws {
        var acknowledgeFirst = try filled()
        acknowledgeFirst.acknowledge(through: try Fixture.sequence(2))
        try record(&acknowledgeFirst, 5, changes: 5)
        var recordFirst = try filled()
        try record(&recordFirst, 5, changes: 5)
        recordFirst.acknowledge(through: try Fixture.sequence(2))
        #expect(acknowledgeFirst == recordFirst)
        #expect(acknowledgeFirst.pendingChanges == 12)
        #expect(acknowledgeFirst.pendingDeltas == 3)
    }

    // MARK: collapse and snapshotApplied

    @Test func collapseReportsExactlyWhatItDropsAndEmptiesTheBacklog() throws {
        var backlog = try filled()
        let report = try backlog.collapse(to: try Fixture.sequence(6))
        #expect(report == PeerBacklogCollapse(droppedDeltas: 4, droppedChanges: 10))
        #expect(backlog.pendingDeltas == 0)
        #expect(backlog.pendingChanges == 0)
        #expect(backlog.requiresSnapshot)
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(6)))
        #expect(backlog.recordedThrough == (try Fixture.sequence(6)))
    }

    @Test func collapseOnlyReportsWhatIsStillPendingAfterAnAcknowledge() throws {
        var backlog = try filled()
        backlog.acknowledge(through: try Fixture.sequence(2))
        let report = try backlog.collapse(to: try Fixture.sequence(4))
        #expect(report == PeerBacklogCollapse(droppedDeltas: 2, droppedChanges: 7))
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(4)))
    }

    @Test func collapseOfAnEmptyBacklogDropsNothingAndStillRequiresASnapshot() throws {
        var backlog = try Fixture.backlog(from: 3)
        let report = try backlog.collapse(to: try Fixture.sequence(3))
        #expect(report == PeerBacklogCollapse(droppedDeltas: 0, droppedChanges: 0))
        #expect(backlog.requiresSnapshot)
        #expect(backlog.recordedThrough == (try Fixture.sequence(3)))
    }

    @Test func collapseRefusesASnapshotBelowTheNewestRecordedAndAcceptsEqual() throws {
        var backlog = try filled()
        let before = backlog
        let behindSequence = try Fixture.sequence(3)
        let behind = Fixture.refusal { () throws(Refusal) -> PeerBacklogCollapse in
            try backlog.collapse(to: behindSequence)
        }
        #expect(behind == .snapshotBehind(newest: try Fixture.sequence(4), found: try Fixture.sequence(3)))
        #expect(backlog == before)
        let equal = try backlog.collapse(to: try Fixture.sequence(4))
        #expect(equal == PeerBacklogCollapse(droppedDeltas: 4, droppedChanges: 10))
    }

    @Test func collapseThenRecordContinuesAfterTheSnapshotSequence() throws {
        var backlog = try filled()
        _ = try backlog.collapse(to: try Fixture.sequence(6))
        let before = backlog
        #expect(try recordRefusal(&backlog, 5, changes: 1) == .sequenceGap(
            expected: try Fixture.sequence(7), found: try Fixture.sequence(5)))
        #expect(backlog == before)
        try record(&backlog, 7, changes: 2)
        #expect(backlog.pendingDeltas == 1)
        #expect(backlog.pendingChanges == 2)
        #expect(backlog.requiresSnapshot)
    }

    @Test func acknowledgeAfterACollapseIgnoresValuesBelowTheSnapshotFloor() throws {
        var backlog = try filled()
        _ = try backlog.collapse(to: try Fixture.sequence(6))
        let before = backlog
        let belowSnapshot = backlog.acknowledge(through: try Fixture.sequence(4))
        #expect(belowSnapshot == 0)
        #expect(backlog == before)
    }

    @Test func snapshotAppliedClearsTheRequirementOnlyAtOrAboveTheFloor() throws {
        var backlog = try filled()
        _ = try backlog.collapse(to: try Fixture.sequence(6))
        let before = backlog
        let below = backlog.snapshotApplied(through: try Fixture.sequence(5))
        #expect(!below)
        #expect(backlog == before)
        #expect(backlog.requiresSnapshot)
        let atFloor = backlog.snapshotApplied(through: try Fixture.sequence(6))
        #expect(atFloor)
        #expect(!backlog.requiresSnapshot)
        let cleared = backlog
        let again = backlog.snapshotApplied(through: try Fixture.sequence(6))
        #expect(!again)
        #expect(backlog == cleared)
    }

    @Test func snapshotAppliedWithoutACollapseChangesNothing() throws {
        var backlog = try filled()
        let before = backlog
        let applied = backlog.snapshotApplied(through: try Fixture.sequence(4))
        #expect(!applied)
        #expect(backlog == before)
    }

    @Test func snapshotAppliedDropsCoveredDeltasAndKeepsLaterOnes() throws {
        var backlog = try filled()
        _ = try backlog.collapse(to: try Fixture.sequence(6))
        try record(&backlog, 7, changes: 2)
        try record(&backlog, 8, changes: 3)
        let applied = backlog.snapshotApplied(through: try Fixture.sequence(7))
        #expect(applied)
        #expect(backlog.pendingDeltas == 1)
        #expect(backlog.pendingChanges == 3)
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(7)))
        #expect(backlog.recordedThrough == (try Fixture.sequence(8)))
        #expect(!backlog.requiresSnapshot)
    }

    @Test func snapshotAppliedAheadOfEverythingRecordedMovesTheStreamForward() throws {
        var backlog = try filled()
        _ = try backlog.collapse(to: try Fixture.sequence(6))
        try record(&backlog, 7, changes: 2)
        let applied = backlog.snapshotApplied(through: try Fixture.sequence(9))
        #expect(applied)
        #expect(backlog.pendingDeltas == 0)
        #expect(backlog.pendingChanges == 0)
        #expect(backlog.acknowledgedThrough == (try Fixture.sequence(9)))
        #expect(backlog.recordedThrough == (try Fixture.sequence(9)))
        try record(&backlog, 10, changes: 1)
        #expect(backlog.pendingDeltas == 1)
    }

    @Test func backlogEqualitySeesTheRequirementTheFloorAndThePendingCounts() throws {
        let base = try filled()
        var collapsed = base
        _ = try collapsed.collapse(to: try Fixture.sequence(4))
        var acknowledged = base
        acknowledged.acknowledge(through: try Fixture.sequence(4))
        #expect(collapsed != acknowledged)
        #expect(collapsed.pendingDeltas == acknowledged.pendingDeltas)
        #expect(collapsed.recordedThrough == acknowledged.recordedThrough)
        var swapped = try Fixture.backlog(deltas: 8, changes: 40)
        for (index, count) in [4, 3, 2, 1].enumerated() { try record(&swapped, index + 1, changes: count) }
        #expect(swapped != base)
        #expect(swapped.pendingChanges == base.pendingChanges)
    }
}
