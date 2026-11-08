import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Dispatch revalidation. `due` takes the contexts the host holds live at that moment, and releases a due batch for
/// dispatch only when the context stored with it at admit is one of them (all four fields equal), whether the batch is
/// on time or late. Every batch `due` releases, dispatched, revoked or refused, loses its tag and its table entry.
extension OSCReceiveContextTests {
    // MARK: Live and not live

    @Test func dueDispatchesBatchWhoseContextIsLive() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let admitted = try Fixture.admit(&wrapper, Fixture.message(1), context)
        let released = try wrapper.due(now: Fixture.host(0), live: [context])
        #expect(released.dispatch.map(\.batch) == admitted && released.dispatch.map(\.context) == [context])
        #expect(released.revoked.isEmpty && released.refusedWithContext.isEmpty)
    }

    @Test func dueRevokesBatchWhoseContextIsNotLive() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context(peer: 1)
        let admitted = try Fixture.admit(&wrapper, Fixture.message(1), context)
        let released = try wrapper.due(now: Fixture.host(0), live: [Fixture.context(peer: 2)])
        #expect(released.revoked.map(\.batch) == admitted && released.revoked.map(\.context) == [context])
        #expect(released.dispatch.isEmpty && released.refusedWithContext.isEmpty)
    }

    @Test func dueRevokesWhenPeerKeyDiffers() throws {
        try expectRevoked(whenLive: Fixture.variant(.peer))
    }

    @Test func dueRevokesWhenHostEpochGenerationDiffers() throws {
        try expectRevoked(whenLive: Fixture.variant(.hostEpoch))
    }

    @Test func dueRevokesWhenConnectionEpochGenerationDiffers() throws {
        try expectRevoked(whenLive: Fixture.variant(.connectionEpoch))
    }

    @Test func dueRevokesWhenPermissionFingerprintDiffers() throws {
        try expectRevoked(whenLive: Fixture.variant(.permission))
    }

    @Test func dueRevokesWhenPermissionDiffersOnlyInScalarEncoding() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        #expect(PermissionFingerprint(rawValue: composed) != PermissionFingerprint(rawValue: decomposed))
        let decomposedContext = try Fixture.context(permission: decomposed)
        try expectRevoked(base: Fixture.context(permission: composed), whenLive: decomposedContext)
    }

    @Test func dueRevalidatesOnTimeBatchesToo() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let admitted = try Fixture.admit(&wrapper, Fixture.message(1), context)
        var control = wrapper
        #expect(try control.due(now: Fixture.host(0), live: [context]).dispatch.map(\.batch.timing) == [.onTime])
        let released = try wrapper.due(now: Fixture.host(0), live: [])
        #expect(released.revoked.map(\.batch) == admitted && released.revoked.map(\.batch.timing) == [.onTime])
        #expect(released.dispatch.isEmpty)
    }

    @Test func dueRevalidatesLateBatchesToo() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let admitted = try Fixture.admit(&wrapper, Fixture.message(1), context)
        let half = Fixture.second / 2
        let late = OSC.ScheduleTiming.late(by: UInt64(half))
        var control = wrapper
        #expect(try control.due(now: Fixture.host(half), live: [context]).dispatch.map(\.batch.timing) == [late])
        let released = try wrapper.due(now: Fixture.host(half), live: [])
        #expect(released.revoked.map(\.batch.id) == admitted.map(\.id))
        #expect(released.revoked.map(\.batch.timing) == [late])
        #expect(released.dispatch.isEmpty && released.refusedWithContext.isEmpty)
    }

    @Test func dueReturnsEachBatchWithTheContextItWasAdmittedUnder() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        let first = try Fixture.admit(&wrapper, Fixture.message(1), alpha)
        let second = try Fixture.admit(&wrapper, Fixture.message(2), bravo)
        let third = try Fixture.admit(&wrapper, Fixture.message(3), alpha)
        let released = try wrapper.due(now: Fixture.host(0), live: [alpha, bravo])
        #expect(released.dispatch.map(\.batch) == first + second + third)
        #expect(released.dispatch.map(\.context) == [alpha, bravo, alpha])
        #expect(released.revoked.isEmpty && released.refusedWithContext.isEmpty)
    }

    @Test func dueWithEmptyLiveSetRevokesEveryDueBatch() throws {
        var wrapper = try Fixture.wrapper()
        let contexts = try Fixture.peers(3)
        let first = try #require(contexts.first)
        var admitted: [OSC.ScheduledBatch] = []
        for (index, context) in contexts.enumerated() {
            admitted += try Fixture.admit(&wrapper, Fixture.message(Int32(index)), context)
        }
        let later = try Fixture.admit(&wrapper, Fixture.timed(Fixture.tag(after: 5), 9), first)
        let released = try wrapper.due(now: Fixture.host(0), live: [])
        #expect(released.revoked.map(\.batch) == admitted && released.revoked.map(\.context) == contexts)
        #expect(released.dispatch.isEmpty && released.refusedWithContext.isEmpty)
        #expect(wrapper.scheduler.pending == later && wrapper.taggedBatchCount == 1)
    }

    @Test func dueSplitsMixedLiveAndRevokedBatches() throws {
        var wrapper = try Fixture.wrapper()
        let contexts = try Fixture.peers(3)
        for value in 0..<6 {
            try Fixture.admit(&wrapper, Fixture.message(Int32(value)), contexts[value % 3])
        }
        let released = try wrapper.due(now: Fixture.host(0), live: [contexts[0], contexts[2]])
        #expect(Fixture.payloads(released.dispatch) == [0, 2, 3, 5])
        #expect(released.dispatch.map(\.context) == [contexts[0], contexts[2], contexts[0], contexts[2]])
        #expect(Fixture.payloads(released.revoked) == [1, 4])
        #expect(released.revoked.map(\.context) == [contexts[1], contexts[1]])
        #expect(released.refusedWithContext.isEmpty && wrapper.taggedBatchCount == 0)
    }

    // MARK: Before the window, and once only

    @Test func dueLeavesBatchesBeforeTheirWindowQueued() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        let now = try Fixture.admit(&wrapper, Fixture.message(1), alpha)
        let later = try Fixture.admit(&wrapper, Fixture.timed(Fixture.tag(after: 5), 2), alpha)
        let dead = try Fixture.admit(&wrapper, Fixture.timed(Fixture.tag(after: 6), 3), bravo)
        let first = try wrapper.due(now: Fixture.host(0), live: [alpha])
        #expect(first.dispatch.map(\.batch) == now)
        #expect(first.revoked.isEmpty && first.refusedWithContext.isEmpty)
        #expect(wrapper.scheduler.pending == later + dead && wrapper.taggedBatchCount == 2)
        #expect(wrapper.pendingCount(for: alpha) == 1 && wrapper.pendingCount(for: bravo) == 1)
        for (batch, context) in zip(later + dead, [alpha, bravo]) {
            #expect(wrapper.context(of: batch.id) == context)
        }
        // A context that is not live does not drop its batch before the window opens: it is revoked when it does.
        let second = try wrapper.due(now: Fixture.host(5 * Fixture.second), live: [alpha])
        let deadID = try #require(dead.first).id
        #expect(second.dispatch.map(\.batch.id) == later.map(\.id) && second.revoked.isEmpty)
        #expect(wrapper.scheduler.pending == dead && wrapper.context(of: deadID) == bravo)
        let third = try wrapper.due(now: Fixture.host(6 * Fixture.second), live: [alpha])
        #expect(third.revoked.map(\.batch.id) == dead.map(\.id) && third.dispatch.isEmpty)
        #expect(wrapper.taggedBatchCount == 0 && wrapper.contextCount == 0)
    }

    @Test func dueDoesNotDispatchTheSameBatchTwice() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let admitted = try Fixture.admit(&wrapper, Fixture.threeBatches(), context)
        var released: [OSC.BatchID] = []
        for step in 0...3 {
            let now = Fixture.host(Int64(step) * Fixture.second)
            let once = try wrapper.due(now: now, live: [context])
            let again = try wrapper.due(now: now, live: [context])
            released += once.dispatch.map(\.batch.id)
            #expect(once.revoked.isEmpty && once.refusedWithContext.isEmpty)
            #expect(again.dispatch.isEmpty && again.revoked.isEmpty && again.refusedWithContext.isEmpty, "step \(step)")
        }
        #expect(released == admitted.map(\.id))
        #expect(wrapper.taggedBatchCount == 0 && wrapper.contextCount == 0 && wrapper.scheduler.pending.isEmpty)
    }

    // MARK: Nothing survives a release

    @Test func dueRemovesTagAndTableEntryOfDispatchedBatches() throws {
        var wrapper = try Fixture.wrapper(limit: 1)
        let alpha = try Fixture.context(peer: 1)
        let admitted = try Fixture.admit(&wrapper, Fixture.spread(3), alpha)
        for (index, batch) in admitted.enumerated() {
            let released = try wrapper.due(now: Fixture.host(Int64(index + 1) * Fixture.second), live: [alpha])
            let left = admitted.count - index - 1
            #expect(released.dispatch.map(\.batch.id) == [batch.id], "step \(index)")
            #expect(wrapper.context(of: batch.id) == nil && wrapper.pendingCount(for: alpha) == left, "step \(index)")
            #expect(wrapper.taggedBatchCount == left && wrapper.contextCount == min(left, 1), "step \(index)")
        }
        #expect(wrapper.scheduler.pending.isEmpty && wrapper.scheduler.pendingMessageCount == 0)
        try Fixture.admit(&wrapper, Fixture.message(9), Fixture.context(peer: 2), at: 3 * Fixture.second)
        #expect(wrapper.contextCount == 1)
    }

    @Test func dueRemovesTagAndTableEntryOfRevokedBatches() throws {
        var wrapper = try Fixture.wrapper(limit: 1)
        let alpha = try Fixture.context(peer: 1)
        let admitted = try Fixture.admit(&wrapper, Fixture.spread(3), alpha)
        for (index, batch) in admitted.enumerated() {
            let released = try wrapper.due(now: Fixture.host(Int64(index + 1) * Fixture.second), live: [])
            let left = admitted.count - index - 1
            #expect(released.revoked.map(\.batch.id) == [batch.id] && released.dispatch.isEmpty, "step \(index)")
            #expect(wrapper.context(of: batch.id) == nil && wrapper.pendingCount(for: alpha) == left, "step \(index)")
            #expect(wrapper.taggedBatchCount == left && wrapper.contextCount == min(left, 1), "step \(index)")
        }
        #expect(wrapper.scheduler.pending.isEmpty && wrapper.scheduler.pendingMessageCount == 0)
        try Fixture.admit(&wrapper, Fixture.message(9), Fixture.context(peer: 2), at: 3 * Fixture.second)
        #expect(wrapper.contextCount == 1)
    }

    @Test func dueRemovesTagAndTableEntryOfRefusedBatches() throws {
        var wrapper = try Fixture.wrapper(limit: 1)
        let alpha = try Fixture.context(peer: 1)
        let admitted = try Fixture.admit(&wrapper, Fixture.spread(3), alpha)
        let released = try wrapper.due(now: Fixture.host(10 * Fixture.second), live: [alpha])
        #expect(released.refusedWithContext.map(\.refused.batch.id) == admitted.map(\.id))
        #expect(released.dispatch.isEmpty && released.revoked.isEmpty)
        for batch in admitted {
            #expect(wrapper.context(of: batch.id) == nil)
        }
        #expect(wrapper.taggedBatchCount == 0 && wrapper.contextCount == 0 && wrapper.pendingCount(for: alpha) == 0)
        #expect(wrapper.scheduler.pending.isEmpty && wrapper.scheduler.pendingMessageCount == 0)
        try Fixture.admit(&wrapper, Fixture.message(9), Fixture.context(peer: 2), at: 10 * Fixture.second)
        #expect(wrapper.contextCount == 1)
    }

    @Test func dueReturnsTooLateBatchesAsRefusedWithContext() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        let first = try Fixture.admit(&wrapper, Fixture.message(1), alpha)
        let second = try Fixture.admit(&wrapper, Fixture.message(2), bravo)
        // Alpha is live and bravo is not: a batch past the late horizon is refused either way, never dispatched.
        let released = try wrapper.due(now: Fixture.host(Fixture.second + 1), live: [alpha])
        #expect(released.dispatch.isEmpty && released.revoked.isEmpty)
        #expect(released.refusedWithContext.map(\.refused.batch) == first + second)
        #expect(released.refusedWithContext.map(\.context) == [alpha, bravo])
        #expect(released.refusedWithContext.map(\.refused.refusal) == [.tooLate(.immediate), .tooLate(.immediate)])
    }

    @Test func dueForwardsNowRegressedAndLeavesWrapperUnchanged() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        try Fixture.admit(&wrapper, Fixture.threeBatches(), context, at: 10)
        let regressed = Inner.nowRegressed(previous: Fixture.host(10), now: Fixture.host(9))
        let withLive = Fixture.refusal(wrapper) { try $0.due(now: Fixture.host(9), live: [context]) }
        let withNone = Fixture.refusal(wrapper) { try $0.due(now: Fixture.host(9), live: []) }
        #expect(withLive == .scheduling(regressed) && withNone == .scheduling(regressed))
        let released = try wrapper.due(now: Fixture.host(10), live: [context])
        #expect(released.dispatch.count == 1 && wrapper.taggedBatchCount == 2)
    }

    // MARK: Ten thousand rounds

    @Test func tenThousandDispatchRoundsLeaveNoTagOrContextEntries() throws {
        let unclean = try Fixture.uncleanRounds(10_000, gap: 0, isLive: true) {
            $0.dispatch.count == 1 && $0.revoked.isEmpty && $0.refusedWithContext.isEmpty
        }
        #expect(unclean == 0)
    }

    @Test func tenThousandRevokeRoundsLeaveNoTagOrContextEntries() throws {
        let unclean = try Fixture.uncleanRounds(10_000, gap: 0, isLive: false) {
            $0.revoked.count == 1 && $0.dispatch.isEmpty && $0.refusedWithContext.isEmpty
        }
        #expect(unclean == 0)
    }

    @Test func tenThousandRefuseRoundsLeaveNoTagOrContextEntries() throws {
        let unclean = try Fixture.uncleanRounds(10_000, gap: Fixture.second + 1, isLive: true) {
            $0.refusedWithContext.count == 1 && $0.dispatch.isEmpty && $0.revoked.isEmpty
        }
        #expect(unclean == 0)
    }

    // MARK: Helpers

    /// Admits one batch under the base context, then runs `due` with only `live` live: the batch is revoked. As a
    /// control, a copy with only the base context live dispatches it, so the field that differs is what revokes it.
    private func expectRevoked(
        base: Context? = nil, whenLive live: Context, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let context = try base ?? Fixture.context()
        var wrapper = try Fixture.wrapper()
        let admitted = try Fixture.admit(&wrapper, Fixture.message(1), context)
        var control = wrapper
        let dispatched = try control.due(now: Fixture.host(0), live: [context])
        #expect(dispatched.dispatch.map(\.batch) == admitted, sourceLocation: sourceLocation)
        #expect(dispatched.revoked.isEmpty, sourceLocation: sourceLocation)
        let released = try wrapper.due(now: Fixture.host(0), live: [live])
        #expect(released.revoked.map(\.batch) == admitted && released.revoked.map(\.context) == [context],
                sourceLocation: sourceLocation)
        #expect(released.dispatch.isEmpty && released.refusedWithContext.isEmpty, sourceLocation: sourceLocation)
    }
}

extension OSCReceiveContextTests.Fixture {
    /// `rounds` rounds on a wrapper that holds at most 8 contexts. Each round admits one `/go` message under another
    /// of 300 peers, lets `gap` ticks pass and runs `due`, with that round's context live or not. Returns how many
    /// rounds released something other than `expected` or left a tag or a context entry behind.
    static func uncleanRounds(
        _ rounds: Int, gap: Int64, isLive: Bool, expected: (OpenSoundControl.ContextDue) -> Bool
    ) throws -> Int {
        var queue = try wrapper(limit: 8)
        let contexts = try peers(300)
        var unclean = 0
        var tick: Int64 = 0
        for round in 0..<rounds {
            let context = contexts[round % contexts.count]
            try admit(&queue, message(Int32(round % 100)), context, at: tick)
            tick += gap
            let released = try queue.due(now: host(tick), live: isLive ? [context] : [])
            if !expected(released) || queue.taggedBatchCount != 0 || queue.contextCount != 0 {
                unclean += 1
            }
        }
        return unclean
    }
}
