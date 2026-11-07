import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The scripted reader: slow, failing, short, interrupted and end-of-source reads without a file or a clock.
extension MediaIOWorkerTests {
    private static func reader(_ steps: [MediaReadStep]) throws -> ScriptedMediaReader {
        ScriptedMediaReader(script: try MediaReadScript(steps: steps))
    }

    @Test
    func io2ReaderSlowReadIsPendingThenReady() throws {
        var reader = try Self.reader([.pending, .pending, .pending, .ready(frames: 8)])
        let request = try Self.readRequest(frames: 8)
        var polls: [MediaReadPoll] = []
        for _ in 0..<4 { polls.append(try reader.read(request)) }
        #expect(polls == [.pending, .pending, .pending, .ready(MediaReadResult(frames: 8, reachedEnd: false))])
        #expect(reader.callCount == 4 && reader.remainingSteps == 0 && reader.scriptViolations == 0)
    }

    @Test
    func io2ReaderFailingReadsThrowTheScriptedFaultAndConsumeTheirStep() throws {
        var reader = try Self.reader([.fail(.ioFailure), .fail(.unavailable), .ready(frames: 1)])
        let request = try Self.readRequest()
        #expect(Self.refusal(MediaReadFault.self) { try reader.read(request) } == .ioFailure)
        #expect(reader.remainingSteps == 2)
        #expect(Self.refusal(MediaReadFault.self) { try reader.read(request) } == .unavailable)
        #expect(reader.remainingSteps == 1)
        #expect(try reader.read(request) == .ready(MediaReadResult(frames: 1, reachedEnd: false)))
        #expect(reader.scriptViolations == 0 && reader.callCount == 3)
    }

    @Test
    func io2ReaderShortReadReturnsFewerFramesThanRequested() throws {
        var reader = try Self.reader([.ready(frames: 3)])
        let poll = try reader.read(try Self.readRequest(frames: 8))
        #expect(poll == .ready(MediaReadResult(frames: 3, reachedEnd: false)))
    }

    @Test
    func io2ReaderInterruptionThenReady() throws {
        var reader = try Self.reader([.fail(.interrupted), .ready(frames: 8)])
        let request = try Self.readRequest()
        #expect(Self.refusal(MediaReadFault.self) { try reader.read(request) } == .interrupted)
        #expect(try reader.read(request) == .ready(MediaReadResult(frames: 8, reachedEnd: false)))
    }

    @Test
    func io2ReaderEndOfSourceSetsReachedEnd() throws {
        var reader = try Self.reader([.readyAtEnd(frames: 5), .readyAtEnd(frames: 0)])
        let request = try Self.readRequest()
        #expect(try reader.read(request) == .ready(MediaReadResult(frames: 5, reachedEnd: true)))
        #expect(try reader.read(request) == .ready(MediaReadResult(frames: 0, reachedEnd: true)))
    }

    @Test
    func io2ReaderExhaustedScriptIsUnavailableAndCountsEveryViolation() throws {
        var reader = try Self.reader([])
        let request = try Self.readRequest()
        #expect(Self.refusal(MediaReadFault.self) { try reader.read(request) } == .unavailable)
        #expect(reader.scriptViolations == 1 && reader.callCount == 1 && reader.requests == [request])
        #expect(Self.refusal(MediaReadFault.self) { try reader.read(request) } == .unavailable)
        #expect(reader.scriptViolations == 2 && reader.callCount == 2 && reader.remainingSteps == 0)
    }

    @Test
    func io2ReaderReturnsAnOverlongScriptedReadAsIs() throws {
        var reader = try Self.reader([.ready(frames: 9), .readyAtEnd(frames: 0)])
        let request = try Self.readRequest(frames: 4)
        #expect(try reader.read(request) == .ready(MediaReadResult(frames: 9, reachedEnd: false)))
        #expect(try reader.read(request) == .ready(MediaReadResult(frames: 0, reachedEnd: true)))
        #expect(reader.scriptViolations == 0)
    }

    @Test
    func io2ReaderRecordsTheFirstTwoHundredFiftySixRequestsAndOnlyCountsLaterOnes() throws {
        var reader = try Self.reader(Array(repeating: .pending, count: 256))
        let lease = try Self.lease()
        for index in 0..<256 {
            let request = try Self.readRequest(frames: 1, start: Int64(index), lease: lease)
            #expect(try reader.read(request) == .pending)
        }
        #expect(reader.callCount == 256 && reader.requests.count == 256)
        let extra = try Self.readRequest(frames: 1, start: 256, lease: lease)
        #expect(Self.refusal(MediaReadFault.self) { try reader.read(extra) } == .unavailable)
        #expect(reader.callCount == 257 && reader.requests.count == 256 && reader.scriptViolations == 1)
        #expect(reader.requests.map(\.startFrame) == (0..<256).map(Int64.init))
    }

    @Test
    func io2ReaderThrowingCallChangesOnlyTheCountersAndTheCursor() throws {
        var reader = try Self.reader([.fail(.ioFailure), .pending])
        let request = try Self.readRequest()
        let before = reader
        #expect(Self.refusal(MediaReadFault.self) { try reader.read(request) } == .ioFailure)
        #expect(reader.callCount == before.callCount + 1)
        #expect(reader.requests == [request] && reader.scriptViolations == 0 && reader.remainingSteps == 1)
    }

    @Test
    func io2ReaderCopiesPlayTheScriptIndependently() throws {
        let original = try Self.reader([.ready(frames: 2), .fail(.interrupted)])
        var first = original
        var second = original
        let request = try Self.readRequest()
        #expect(try first.read(request) == .ready(MediaReadResult(frames: 2, reachedEnd: false)))
        #expect(Self.refusal(MediaReadFault.self) { try first.read(request) } == .interrupted)
        #expect(try second.read(request) == .ready(MediaReadResult(frames: 2, reachedEnd: false)))
        #expect(second.remainingSteps == 1 && original.remainingSteps == 2 && original.callCount == 0)
    }

    @Test
    func io2ReaderSaturatingSumBacksTheCallCounter() {
        #expect(PrefetchFillCounters.saturatingSum(UInt64.max, 1) == UInt64.max)
        #expect(PrefetchFillCounters.saturatingSum(UInt64.max - 1, 1) == UInt64.max)
        #expect(PrefetchFillCounters.saturatingSum(UInt64.max - 1, 2) == UInt64.max)
        #expect(PrefetchFillCounters.saturatingSum(2, 3) == 5)
        #expect(PrefetchFillCounters.saturatingSum(0, 0) == 0)
    }
}
