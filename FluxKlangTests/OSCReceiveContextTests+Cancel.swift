import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Cancelling one batch by id and every batch of one context. Both keep the tags, the context table and the inner
/// scheduler's counters in step.
extension OSCReceiveContextTests {
    @Test func cancelByIdRemovesTagAndTableEntry() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        let kept = try #require(try Fixture.admit(&wrapper, Fixture.message(1), alpha).first)
        let removed = try #require(try Fixture.admit(&wrapper, Fixture.message(2), bravo).first)
        let cancelled = try wrapper.cancel(removed.id)
        #expect(cancelled.batch == removed && cancelled.context == bravo)
        #expect(wrapper.context(of: removed.id) == nil && wrapper.pendingCount(for: bravo) == 0)
        #expect(wrapper.context(of: kept.id) == alpha && wrapper.pendingCount(for: alpha) == 1)
        #expect(wrapper.taggedBatchCount == 1 && wrapper.contextCount == 1)
        #expect(wrapper.scheduler.pending == [kept] && wrapper.scheduler.pendingMessageCount == 1)
    }

    @Test func cancelByIdKeepsOtherBatchesOfTheSameContext() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let batches = try Fixture.admit(&wrapper, Fixture.threeBatches(), context)
        let middle = try #require(batches.dropFirst().first)
        let cancelled = try wrapper.cancel(middle.id)
        let remaining = batches.filter { $0.id != middle.id }
        #expect(cancelled.batch == middle && remaining.count == 2)
        #expect(wrapper.pendingCount(for: context) == 2 && wrapper.taggedBatchCount == 2 && wrapper.contextCount == 1)
        #expect(wrapper.scheduler.pending == remaining && wrapper.scheduler.pendingMessageCount == 2)
        for batch in remaining {
            #expect(wrapper.context(of: batch.id) == context)
        }
    }

    @Test func cancelByIdOfAnUnqueuedBatchRefusesAndLeavesWrapperUnchanged() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let dispatched = try #require(try Fixture.admit(&wrapper, Fixture.message(1), context).first)
        _ = try wrapper.due(now: Fixture.host(0), live: [context])
        try Fixture.admit(&wrapper, Fixture.spread(2), context)
        let cancelled = try #require(try Fixture.admit(&wrapper, Fixture.message(7), context).first)
        _ = try wrapper.cancel(cancelled.id)
        var foreign = try Fixture.wrapper()
        let stranger = try #require(try Fixture.admit(&foreign, Fixture.spread(11), context).last)
        #expect(wrapper.taggedBatchCount == 2 && stranger.id.value == 10)
        for id in [dispatched.id, cancelled.id, stranger.id] {
            #expect(Fixture.refusal(wrapper) { try $0.cancel(id) } == .scheduling(.batchNotPending(id)))
        }
    }

    @Test func cancelByContextRemovesOnlyThatContext() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        let first = try Fixture.admit(&wrapper, Fixture.message(1), alpha)
        let other = try #require(try Fixture.admit(&wrapper, Fixture.message(2), bravo).first)
        let last = try Fixture.admit(&wrapper, Fixture.message(3), alpha)
        let removed = wrapper.cancel(context: alpha)
        #expect(removed == (first + last).map(\.id) && removed.count == 2)
        #expect(wrapper.scheduler.pending == [other] && wrapper.context(of: other.id) == bravo)
        #expect(wrapper.pendingCount(for: alpha) == 0 && wrapper.pendingCount(for: bravo) == 1)
        #expect(wrapper.taggedBatchCount == 1 && wrapper.contextCount == 1)
        for batch in first + last {
            #expect(wrapper.context(of: batch.id) == nil)
        }
    }

    @Test func cancelByContextRemovesEveryBatchOfThatContext() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let three = try Fixture.admit(&wrapper, Fixture.threeBatches(), context)
        let more = try Fixture.admit(&wrapper, Fixture.spread(2, first: 10), context)
        let removed = wrapper.cancel(context: context)
        #expect(removed == (three + more).map(\.id) && removed.count == 5)
        #expect(wrapper.scheduler.pending.isEmpty && wrapper.scheduler.pendingMessageCount == 0)
        #expect(wrapper.taggedBatchCount == 0 && wrapper.contextCount == 0)
    }

    @Test func cancelByContextReturnsIdsAscendingByValueNotInQueueOrder() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        for step in 0..<40 {
            let tag = Fixture.tag(after: Int64(40 - step))
            try Fixture.admit(&wrapper, Fixture.timed(tag, Int32(step)), step.isMultiple(of: 2) ? alpha : bravo)
        }
        // The expected ids are built outside the `#expect`s: as one expression, the compiler gave up type-checking the
        // range arithmetic together with the comparison.
        let queueOrder: [UInt64] = (0..<40).reversed().map { (id: Int) in UInt64(id) }
        let alphaIDs: [UInt64] = (0..<20).map { (step: Int) in UInt64(step * 2) }
        let bravoIDs: [UInt64] = (0..<20).map { (step: Int) in UInt64(step * 2 + 1) }
        let bravoQueueOrder: [UInt64] = (0..<20).reversed().map { (step: Int) in UInt64(step * 2 + 1) }
        // The later the bundle, the earlier the id: the queue runs from id 39 down to id 0.
        #expect(wrapper.scheduler.pending.map(\.id.value) == queueOrder)
        let removed = wrapper.cancel(context: alpha)
        #expect(removed.map(\.value) == alphaIDs)
        #expect(wrapper.scheduler.pending.map(\.id.value) == bravoQueueOrder)
        #expect(wrapper.cancel(context: bravo).map(\.value) == bravoIDs)
    }

    @Test func cancelByContextOfAnUnknownContextReturnsEmptyAndLeavesWrapperUnchanged() throws {
        var empty = try Fixture.wrapper()
        let emptyBefore = empty
        #expect(empty.cancel(context: try Fixture.context()).isEmpty)
        #expect(empty == emptyBefore)
        var wrapper = try Fixture.wrapper()
        try Fixture.admit(&wrapper, Fixture.threeBatches(), Fixture.context())
        try Fixture.admit(&wrapper, Fixture.message(9), Fixture.variant(.hostEpoch))
        let before = wrapper
        for field in [ContextField.peer, .connectionEpoch, .permission] {
            let removed = wrapper.cancel(context: try Fixture.variant(field))
            #expect(removed.isEmpty, "\(field)")
            #expect(wrapper == before, "\(field)")
        }
        #expect(wrapper.scheduler.pendingMessageCount == 4)
    }

    @Test func cancelByContextKeepsPendingMessageCountConsistent() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        let three = Fixture.bundle(.immediate, [try Fixture.message(1), try Fixture.message(2), try Fixture.message(3)])
        let two = Fixture.bundle(.immediate, [try Fixture.message(4), try Fixture.message(5)])
        let four = Fixture.bundle(.immediate, try (6...9).map { try Fixture.message($0) })
        try Fixture.admit(&wrapper, three, alpha)
        try Fixture.admit(&wrapper, four, bravo)
        try Fixture.admit(&wrapper, two, alpha)
        #expect(wrapper.scheduler.pending.map(\.messages.count) == [3, 4, 2])
        #expect(wrapper.scheduler.pendingMessageCount == 9)
        #expect(wrapper.cancel(context: alpha).count == 2)
        #expect(wrapper.scheduler.pendingMessageCount == 4 && wrapper.scheduler.pending.map(\.messages.count) == [4])
        #expect(wrapper.cancel(context: bravo).count == 1)
        #expect(wrapper.scheduler.pendingMessageCount == 0 && wrapper.scheduler.pending.isEmpty)
    }

    @Test func cancelByContextKeepsBatchesOfContextsDifferingInOneField() throws {
        var wrapper = try Fixture.wrapper()
        let base = try Fixture.context()
        let own = try Fixture.admit(&wrapper, Fixture.message(1), base)
        var others: [OSC.ScheduledBatch] = []
        for field in ContextField.allCases {
            others += try Fixture.admit(&wrapper, Fixture.message(10), Fixture.variant(field))
        }
        let removed = wrapper.cancel(context: base)
        #expect(removed == own.map(\.id) && removed.count == 1)
        #expect(wrapper.scheduler.pending == others && wrapper.contextCount == 4 && wrapper.taggedBatchCount == 4)
        for field in ContextField.allCases {
            #expect(try wrapper.pendingCount(for: Fixture.variant(field)) == 1, "\(field)")
        }
    }

    @Test func tenThousandAdmitAndCancelRoundsLeaveNoTagOrContextEntries() throws {
        var wrapper = try Fixture.wrapper(limit: 8)
        let contexts = try Fixture.peers(300)
        var unclean = 0
        for round in 0..<10_000 {
            let context = contexts[round % contexts.count]
            let admitted = try Fixture.admit(&wrapper, Fixture.message(Int32(round % 100)), context, at: Int64(round))
            let ids = admitted.map(\.id)
            let removed: [OSC.BatchID]
            if round.isMultiple(of: 2) {
                removed = try ids.map { try wrapper.cancel($0).batch.id }
            } else {
                removed = wrapper.cancel(context: context)
            }
            if ids.count != 1 || removed != ids || wrapper.taggedBatchCount != 0 || wrapper.contextCount != 0 {
                unclean += 1
            }
        }
        #expect(unclean == 0)
        #expect(wrapper.scheduler.pending.isEmpty && wrapper.scheduler.pendingMessageCount == 0)
    }
}
