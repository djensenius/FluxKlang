import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The limits of the capture write drain pump (#109 WDP1) at N and N + 1, its counters, the ring, its composition with
/// the scripted writer and a gated scan of its sources. Pure values only: no file, thread, time or randomness.
@Suite("Capture write drain pump limits", .productionAccessAudit)
struct CaptureDrainLimitTests {
    @Test func captureDrainBoundsOneAndTheLargestAreAcceptedAndZeroAndOneOverAreRefused() throws {
        let smallest = try CaptureDrainPump.make(startFrame: 0, pendingBound: 1)
        #expect(smallest.pendingBound == 1)
        #expect(smallest.ring.count == 1)
        let largest = try CaptureDrainPump.make(startFrame: 0, pendingBound: 1_024)
        #expect(largest.pendingBound == 1_024)
        #expect(largest.ring.count == 1_024)
        let zero = limitRefusal { try CaptureDrainPump.make(startFrame: 0, pendingBound: 0) }
        #expect(zero == .pendingBoundOutOfRange(bound: 0, maximum: 1_024))
        let over = limitRefusal { try CaptureDrainPump.make(startFrame: 0, pendingBound: 1_025) }
        #expect(over == .pendingBoundOutOfRange(bound: 1_025, maximum: 1_024))
        let huge = limitRefusal { try CaptureDrainPump.make(startFrame: 0, pendingBound: Int.max) }
        #expect(huge == .pendingBoundOutOfRange(bound: Int.max, maximum: 1_024))
    }

    @Test func captureDrainAFullQueuePadsTheNewestBlockAtBoundsOneAndThree() throws {
        let leases = try limitLeases()
        for bound in [1, 3] {
            var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: bound)
            for index in 0..<bound {
                let outcome = try pump.enqueue(lease: leases[index], frames: 4)
                #expect(outcome == .queued(pending: index + 1))
            }
            let overflow = try pump.enqueue(lease: leases[5], frames: 4)
            let start = Int64(bound * 4)
            #expect(overflow == .padded(CaptureDrainOverflow(startFrame: start, frames: 4), returning: leases[5]))
            #expect(pump.pendingBlocks == bound)
            #expect(pump.paddedFrames == 4)
            let head = try #require(pump.ring[0])
            #expect(head.lease == leases[0])
        }
    }

    @Test func captureDrainAFullQueueOfTheLargestBoundPadsTheNextBlockAndThenDrainsInOrder() throws {
        let spare = try limitLeases(2)
        let leases = try limitLeases(1_024)
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 1_024)
        for index in 0..<1_024 {
            let outcome = try pump.enqueue(lease: leases[index], frames: 1)
            #expect(outcome == .queued(pending: index + 1))
        }
        let overflow = try pump.enqueue(lease: spare[0], frames: 1)
        #expect(overflow == .padded(CaptureDrainOverflow(startFrame: 1_024, frames: 1), returning: spare[0]))
        var starts: [Int64] = []
        for _ in 0..<1_024 {
            let step = try pump.nextWrite()
            let ticket = try #require(step.limitTicket)
            _ = try pump.receive(ticket.id, .accepted(frames: 1))
            starts.append(ticket.request.startFrame)
        }
        let expected = (0..<1_024).map { Int64($0) }
        #expect(starts == expected)
        #expect(pump.pendingBlocks == 0)
        #expect(pump.counters.blocksWritten == 1_024)
        let next = try pump.enqueue(lease: spare[1], frames: 1)
        #expect(next == .queued(pending: 1))
    }

    @Test func captureDrainEnqueueAcceptsOneAndTheLargestFrameCountAndRefusesZeroAndOneOver() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 4)
        let one = try pump.enqueue(lease: leases[0], frames: 1)
        #expect(one == .queued(pending: 1))
        let largest = try pump.enqueue(lease: leases[1], frames: 65_536)
        #expect(largest == .queued(pending: 2))
        #expect(pump.streamEnd == 65_537)
        limitRefused(&pump, .request(.framesOutOfRange(frames: 0, maximum: 65_536))) {
            _ = try $0.enqueue(lease: leases[2], frames: 0)
        }
        limitRefused(&pump, .request(.framesOutOfRange(frames: 65_537, maximum: 65_536))) {
            _ = try $0.enqueue(lease: leases[2], frames: 65_537)
        }
        limitRefused(&pump, .request(.framesOutOfRange(frames: -1, maximum: 65_536))) {
            _ = try $0.enqueue(lease: leases[2], frames: -1)
        }
    }

    @Test func captureDrainPaddingAcceptsOneAndTheLargestFrameCountAndRefusesZeroAndOneOver() throws {
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        let one = try pump.pad(frames: 1)
        #expect(one == .padded(CaptureDrainOverflow(startFrame: 0, frames: 1)))
        let largest = try pump.pad(frames: 4_294_967_295)
        #expect(largest == .padded(CaptureDrainOverflow(startFrame: 1, frames: 4_294_967_295)))
        #expect(pump.paddedFrames == 4_294_967_296)
        limitRefused(&pump, .paddingFramesOutOfRange(frames: 0, maximum: 4_294_967_295)) { _ = try $0.pad(frames: 0) }
        limitRefused(&pump, .paddingFramesOutOfRange(frames: 4_294_967_296, maximum: 4_294_967_295)) {
            _ = try $0.pad(frames: 4_294_967_296)
        }
        limitRefused(&pump, .paddingFramesOutOfRange(frames: -1, maximum: 4_294_967_295)) { _ = try $0.pad(frames: -1) }
    }

    @Test func captureDrainTheLastFrameBeforeTheInt64MaximumIsAcceptedAndOneMoreIsRefused() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: Int64.max - 10, pendingBound: 2)
        limitRefused(&pump, .request(.frameOverflow(startFrame: Int64.max - 10, frames: 11))) {
            _ = try $0.enqueue(lease: leases[0], frames: 11)
        }
        let fits = try pump.enqueue(lease: leases[0], frames: 10)
        #expect(fits == .queued(pending: 1))
        #expect(pump.streamEnd == Int64.max)
        limitRefused(&pump, .request(.frameOverflow(startFrame: Int64.max, frames: 1))) {
            _ = try $0.enqueue(lease: leases[1], frames: 1)
        }
        limitRefused(&pump, .request(.frameOverflow(startFrame: Int64.max, frames: 1))) { _ = try $0.pad(frames: 1) }
    }

    @Test func captureDrainADuplicateLeaseIsRefusedUntilItsBlockWasWrittenAndThenAccepted() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        limitRefused(&pump, .leaseAlreadyQueued) { _ = try $0.enqueue(lease: leases[0], frames: 4) }
        let ticket = try limitIssue(&pump)
        limitRefused(&pump, .leaseAlreadyQueued) { _ = try $0.enqueue(lease: leases[0], frames: 4) }
        _ = try pump.receive(ticket.id, .accepted(frames: 4))
        let again = try pump.enqueue(lease: leases[0], frames: 4)
        #expect(again == .queued(pending: 1))
    }

    @Test func captureDrainAWrittenBlockFreesItsSlotSoTheNextEnqueueIsQueuedAndNotPadded() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        _ = try pump.enqueue(lease: leases[1], frames: 4)
        let padded = try pump.enqueue(lease: leases[2], frames: 4)
        #expect(padded == .padded(CaptureDrainOverflow(startFrame: 8, frames: 4), returning: leases[2]))
        let ticket = try limitIssue(&pump)
        _ = try pump.receive(ticket.id, .accepted(frames: 4))
        let queued = try pump.enqueue(lease: leases[2], frames: 4)
        #expect(queued == .queued(pending: 2))
        #expect(pump.streamEnd == 16)
        var single = try CaptureDrainPump.make(startFrame: 0, pendingBound: 1)
        _ = try single.enqueue(lease: leases[0], frames: 4)
        let only = try limitIssue(&single)
        _ = try single.receive(only.id, .accepted(frames: 4))
        let idle = try single.nextWrite()
        #expect(idle == .idle(.empty))
    }

    @Test func captureDrainTheRingWrapsAroundAndKeepsBlocksInIssueOrderAtBoundThree() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 2)
        var starts: [Int64] = []
        for index in 1...10 {
            let outcome = try pump.enqueue(lease: leases[index % 8], frames: 2)
            #expect(outcome == .queued(pending: 2))
            let ticket = try limitIssue(&pump)
            starts.append(ticket.request.startFrame)
            _ = try pump.receive(ticket.id, .accepted(frames: 2))
        }
        #expect(starts == [0, 2, 4, 6, 8, 10, 12, 14, 16, 18])
        #expect(pump.pendingBlocks == 1)
        #expect(pump.headIndex == 1)
    }

    @Test func captureDrainEveryRefusingMethodLeavesThePumpEqualToItsSavedCopy() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: 7, pendingBound: 3)
        _ = try pump.enqueue(lease: leases[0], frames: 5)
        _ = try pump.pad(frames: 2)
        let ticket = try limitIssue(&pump)
        let bad = try MediaWriteFinish.make(acceptedFrames: 9, durableFrames: 9)
        limitRefused(&pump, .request(.framesOutOfRange(frames: 0, maximum: 65_536))) {
            _ = try $0.enqueue(lease: leases[1], frames: 0)
        }
        limitRefused(&pump, .paddingFramesOutOfRange(frames: 0, maximum: 4_294_967_295)) { _ = try $0.pad(frames: 0) }
        limitRefused(&pump, .unknownTicket(99)) { _ = try $0.receive(99, .pending) }
        limitRefused(&pump, .acceptedFramesOutOfRange(accepted: 6, requested: 5)) {
            _ = try $0.receive(ticket.id, .accepted(frames: 6))
        }
        limitRefused(&pump, .unknownTicket(99)) { _ = try $0.fail(99, .diskFull) }
        limitRefused(&pump, .notStopped) { _ = try $0.reclaim() }
        limitRefused(&pump, .writeInFlight) { _ = try $0.finish(bad) }
        limitRefused(&pump, .writeInFlight) { _ = try $0.finishFailed(.diskFull) }
        _ = try pump.receive(ticket.id, .accepted(frames: 5))
        limitRefused(&pump, .acceptedMismatch(worker: 9, pump: 5)) { _ = try $0.finish(bad) }
    }

    @Test func captureDrainNoCounterEverDecreasesAcrossARunWithRetriesPaddingAndAStop() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        var seen = pump.counters.values
        func check() {
            let now = pump.counters.values
            #expect(limitNondecreasing(seen, now))
            seen = now
        }
        _ = try pump.enqueue(lease: leases[0], frames: 6)
        check()
        _ = try pump.enqueue(lease: leases[1], frames: 6)
        _ = try pump.enqueue(lease: leases[2], frames: 6)
        check()
        let first = try limitIssue(&pump)
        _ = try pump.receive(first.id, .pending)
        check()
        _ = try pump.receive(first.id, .accepted(frames: 2))
        check()
        let second = try limitIssue(&pump)
        _ = try pump.fail(second.id, .ioFailure)
        check()
        let third = try limitIssue(&pump)
        _ = try pump.receive(third.id, .accepted(frames: 4))
        check()
        let fourth = try limitIssue(&pump)
        _ = try pump.fail(fourth.id, .diskFull)
        check()
        _ = try pump.enqueue(lease: leases[3], frames: 3)
        check()
        _ = try pump.reclaim()
        check()
        let counters = pump.counters
        #expect(counters.ticketsIssued == 4)
        #expect(counters.retriesScheduled == 1)
        #expect(counters.faultsLatched == 1)
        #expect(counters.framesAfterStop == 3)
        #expect(counters.backpressureBlocks == 1)
        #expect(counters.blocksReclaimed == 1)
    }

    @Test func captureDrainComposesWithTheScriptedWriterAndAgreesOnTheAcceptedFrames() throws {
        let leases = try limitLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 4)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        _ = try pump.enqueue(lease: leases[1], frames: 20)
        let steps: [MediaWriteStep] = [.accept(frames: 6), .pending, .accept(frames: 4), .fail(.interrupted),
                                       .accept(frames: 20)]
        let script = try MediaWriteScript(steps: steps, finish: .durableShortBy(frames: 3))
        var writer = ScriptedMediaWriter(script: script)
        try limitDrive(&pump, &writer)
        #expect(pump.pendingBlocks == 0)
        #expect(pump.acceptedFrames == writer.acceptedFrames)
        #expect(pump.acceptedFrames == 30)
        #expect(pump.counters.ticketsIssued == 4)
        #expect(pump.counters.slowPolls == 1)
        #expect(pump.counters.retriesScheduled == 1)
        #expect(writer.scriptViolations == 0)
        #expect(writer.remainingSteps == 0)
        let result = try writer.finish()
        let summary = try pump.finish(result)
        #expect(summary.isPartial)
        #expect(summary.missingFrames == 3)
        #expect(summary.sealing == .sealed(durableFrames: 27))
        #expect(summary.stopReason == nil)
    }

    private static let sourceNames = ["CaptureDrainTypes.swift", "CaptureDrainRefusal.swift", "CaptureDrainPump.swift",
                                      "CaptureDrainPump+Write.swift"]

    /// The production files of the pump, read from the checkout or from the package mirror; empty when absent.
    static func captureSources() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Media/IO/Capture/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = sourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == sourceNames.count { return texts }
        }
        return []
    }

    @Test func captureDrainEnqueueRefusesFinishedBeforeAZeroFrameCountAndLeavesThePumpUnchanged() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        let result = try MediaWriteFinish.make(acceptedFrames: 0, durableFrames: 0)
        _ = try pump.finish(result)
        expectDrainRefused(&pump, .alreadyFinished) { _ = try $0.enqueue(lease: leases[0], frames: 0) }
    }

    @Test func captureDrainEnqueueRefusesTheSpanBeforeADuplicateLeaseWhenBothAreWrong() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        expectDrainRefused(&pump, .request(.framesOutOfRange(frames: 65_537, maximum: 65_536))) {
            _ = try $0.enqueue(lease: leases[0], frames: 65_537)
        }
        expectDrainRefused(&pump, .leaseAlreadyQueued) { _ = try $0.enqueue(lease: leases[0], frames: 4) }
    }

    @Test func captureDrainAStoppedPumpStillRefusesAMalformedEnqueueInsteadOfSwallowingIt() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 0, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 4)
        let ticket = try drainIssue(&pump)
        _ = try pump.fail(ticket.id, .diskFull)
        expectDrainRefused(&pump, .request(.framesOutOfRange(frames: 0, maximum: 65_536))) {
            _ = try $0.enqueue(lease: leases[1], frames: 0)
        }
        expectDrainRefused(&pump, .leaseAlreadyQueued) { _ = try $0.enqueue(lease: leases[0], frames: 4) }
        expectDrainRefused(&pump, .paddingFramesOutOfRange(frames: 0, maximum: 4_294_967_295)) {
            _ = try $0.pad(frames: 0)
        }
    }

    @Test func captureDrainPadRefusesTheFramesRangeBeforeOverflowAndFinishedBeforeBoth() throws {
        var pump = try CaptureDrainPump.make(startFrame: Int64.max - 10, pendingBound: 2)
        let tooMany = 4_294_967_296
        expectDrainRefused(&pump, .paddingFramesOutOfRange(frames: tooMany, maximum: 4_294_967_295)) {
            _ = try $0.pad(frames: tooMany)
        }
        expectDrainRefused(&pump, .request(.frameOverflow(startFrame: Int64.max - 10, frames: 11))) {
            _ = try $0.pad(frames: 11)
        }
        let result = try MediaWriteFinish.make(acceptedFrames: 0, durableFrames: 0)
        _ = try pump.finish(result)
        expectDrainRefused(&pump, .alreadyFinished) { _ = try $0.pad(frames: 0) }
    }

    @Test func captureDrainTheFrameInvariantHoldsAfterEveryCallOfAFixedSequence() throws {
        let leases = try drainLeases()
        var pump = try CaptureDrainPump.make(startFrame: 5, pendingBound: 2)
        _ = try pump.enqueue(lease: leases[0], frames: 10)
        expectBalanced(pump)
        _ = try pump.enqueue(lease: leases[1], frames: 6)
        expectBalanced(pump)
        _ = try pump.enqueue(lease: leases[2], frames: 4)
        expectBalanced(pump)
        _ = try pump.pad(frames: 3)
        expectBalanced(pump)
        let first = try drainIssue(&pump)
        expectBalanced(pump)
        _ = try pump.receive(first.id, .pending)
        expectBalanced(pump)
        _ = try pump.receive(first.id, .accepted(frames: 4))
        expectBalanced(pump)
        let second = try drainIssue(&pump)
        _ = try pump.fail(second.id, .ioFailure)
        expectBalanced(pump)
        let third = try drainIssue(&pump)
        _ = try pump.receive(third.id, .accepted(frames: 6))
        expectBalanced(pump)
        _ = try pump.enqueue(lease: leases[2], frames: 4)
        expectBalanced(pump)
        let fourth = try drainIssue(&pump)
        _ = try pump.receive(fourth.id, .accepted(frames: 6))
        expectBalanced(pump)
        let fifth = try drainIssue(&pump)
        _ = try pump.receive(fifth.id, .accepted(frames: 1))
        expectBalanced(pump)
        _ = try pump.pad(frames: 7)
        expectBalanced(pump)
        _ = try pump.enqueue(lease: leases[3], frames: 2)
        expectBalanced(pump)
        for fault in [MediaWriteFault.interrupted, .ioFailure, .interrupted, .ioFailure] {
            let ticket = try drainIssue(&pump)
            _ = try pump.fail(ticket.id, fault)
            expectBalanced(pump)
        }
        _ = try pump.enqueue(lease: leases[0], frames: 5)
        expectBalanced(pump)
        _ = try pump.pad(frames: 2)
        expectBalanced(pump)
        _ = try pump.nextWrite()
        expectBalanced(pump)
        while try pump.reclaim() != nil { expectBalanced(pump) }
        expectBalanced(pump)
        let result = try MediaWriteFinish.make(acceptedFrames: 17, durableFrames: 17)
        let summary = try pump.finish(result)
        expectBalanced(pump)
        let spent = summary.acceptedFrames + summary.paddedFrames + summary.unwrittenFrames + summary.reclaimedFrames
        #expect(summary.streamFrames == spent)
        #expect(summary.reclaimedFrames == 5)
    }

    @Test(.enabled(if: !CaptureDrainLimitTests.captureSources().isEmpty))
    func captureDrainTheFourProductionFilesAreReadAndNameNoBannedText() {
        let texts = Self.captureSources()
        #expect(texts.count == 4)
        let banned = ["Ta" + "sk", "Cl" + "ock", "Da" + "te", "Codab" + "le", "FileMan" + "ager", "Dispatch" + "Queue",
                      "defa" + "ult:", "try" + "!", "static " + "var", "remove" + "First", "first" + "Index",
                      "first(" + "where", ".fil" + "ter", ".sor" + "ted", "var next = " + "self", "import "]
        for text in texts {
            for token in banned { #expect(!text.contains(token)) }
        }
    }
}

fileprivate extension CaptureDrainStep {
    var limitTicket: CaptureDrainTicket? {
        if case .write(let ticket) = self { return ticket }
        return nil
    }
}

private func limitLeases(_ count: Int = 8) throws -> [MediaBlockLease] {
    let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: max(count, 2), headFrames: 64)
    let pool = try MediaBlockPool.make(plan: plan, channelCount: 1)
    var leases: [MediaBlockLease] = []
    for _ in 0..<count { leases.append(try pool.lease()) }
    return leases
}

private func limitRefusal<Value>(_ body: () throws -> Value) -> CaptureDrainRefusal? {
    do {
        _ = try body()
        return nil
    } catch {
        return error as? CaptureDrainRefusal
    }
}

private func limitRefused(
    _ pump: inout CaptureDrainPump,
    _ expected: CaptureDrainRefusal,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (inout CaptureDrainPump) throws -> Void
) {
    let before = pump
    var caught: CaptureDrainRefusal?
    do {
        try body(&pump)
    } catch {
        caught = error as? CaptureDrainRefusal
    }
    #expect(caught == expected, sourceLocation: sourceLocation)
    #expect(pump == before, sourceLocation: sourceLocation)
}

private func limitIssue(_ pump: inout CaptureDrainPump) throws -> CaptureDrainTicket {
    let step = try pump.nextWrite()
    return try #require(step.limitTicket)
}

private func limitNondecreasing(_ before: [UInt64], _ after: [UInt64]) -> Bool {
    guard before.count == after.count else { return false }
    for (old, new) in zip(before, after) where new < old { return false }
    return true
}

/// Plays one writer against the pump until it has nothing to issue: poll again on `pending`, report a fault on a throw.
private func limitDrive(_ pump: inout CaptureDrainPump, _ writer: inout ScriptedMediaWriter) throws {
    while case .write(let ticket) = try pump.nextWrite() {
        var settled = false
        while !settled {
            let poll: MediaWritePoll
            do throws(MediaWriteFault) {
                poll = try writer.write(ticket.request)
            } catch {
                _ = try pump.fail(ticket.id, error)
                break
            }
            let outcome = try pump.receive(ticket.id, poll)
            settled = !limitIsPending(outcome)
        }
    }
}

private func limitIsPending(_ outcome: CaptureDrainOutcome) -> Bool {
    if case .stillPending = outcome { return true }
    return false
}
