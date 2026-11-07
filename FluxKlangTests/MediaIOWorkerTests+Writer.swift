import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The scripted writer: slow, short, interrupted and disk-full writes, durable and partial finishes.
extension MediaIOWorkerTests {
    private static func writer(_ steps: [MediaWriteStep],
                               finish: MediaWriteFinishStep = .durable) throws -> ScriptedMediaWriter {
        ScriptedMediaWriter(script: try MediaWriteScript(steps: steps, finish: finish))
    }

    @Test
    func io2WriterDiskFullKeepsTheFramesAlreadyAccepted() throws {
        var writer = try Self.writer([.accept(frames: 10), .fail(.diskFull), .accept(frames: 1)])
        let request = try Self.writeRequest(frames: 10)
        #expect(try writer.write(request) == .accepted(frames: 10))
        #expect(Self.refusal(MediaWriteFault.self) { try writer.write(request) } == .diskFull)
        #expect(writer.acceptedFrames == 10 && writer.callCount == 2 && writer.remainingSteps == 1)
        let finish = try writer.finish()
        #expect(finish.acceptedFrames == 10 && finish.durableFrames == 10 && !finish.isPartial)
    }

    @Test
    func io2WriterShortAcceptAndOverAcceptAreReturnedAsScripted() throws {
        var writer = try Self.writer([.accept(frames: 3), .accept(frames: 9)])
        #expect(try writer.write(try Self.writeRequest(frames: 8)) == .accepted(frames: 3))
        #expect(writer.acceptedFrames == 3)
        #expect(try writer.write(try Self.writeRequest(frames: 4)) == .accepted(frames: 9))
        #expect(writer.acceptedFrames == 12)
    }

    @Test
    func io2WriterPendingAndInterruptionChangeNoAcceptedFrames() throws {
        var writer = try Self.writer([.pending, .fail(.interrupted), .fail(.ioFailure), .fail(.unavailable)])
        let request = try Self.writeRequest()
        #expect(try writer.write(request) == .pending)
        #expect(Self.refusal(MediaWriteFault.self) { try writer.write(request) } == .interrupted)
        #expect(Self.refusal(MediaWriteFault.self) { try writer.write(request) } == .ioFailure)
        #expect(Self.refusal(MediaWriteFault.self) { try writer.write(request) } == .unavailable)
        #expect(writer.acceptedFrames == 0 && writer.callCount == 4 && writer.scriptViolations == 0)
    }

    @Test
    func io2WriterDurableFinishReportsEveryAcceptedFrameAsDurable() throws {
        var writer = try Self.writer([.accept(frames: 7), .accept(frames: 5)])
        _ = try writer.write(try Self.writeRequest())
        _ = try writer.write(try Self.writeRequest())
        let finish = try writer.finish()
        #expect(finish == (try MediaWriteFinish.make(acceptedFrames: 12, durableFrames: 12)))
        #expect(writer.isFinished)
    }

    @Test
    func io2WriterPartialFileReportsTheMissingFrames() throws {
        var writer = try Self.writer([.accept(frames: 12)], finish: .durableShortBy(frames: 5))
        _ = try writer.write(try Self.writeRequest())
        let finish = try writer.finish()
        #expect(finish.acceptedFrames == 12 && finish.durableFrames == 7)
        #expect(finish.isPartial && finish.missingFrames == 5)
    }

    @Test
    func io2WriterShortByEqualToAcceptedIsAllowedAndOneMoreIsAViolation() throws {
        var exact = try Self.writer([.accept(frames: 12)], finish: .durableShortBy(frames: 12))
        _ = try exact.write(try Self.writeRequest())
        let finish = try exact.finish()
        #expect(finish.durableFrames == 0 && finish.missingFrames == 12 && exact.scriptViolations == 0)
        var over = try Self.writer([.accept(frames: 12)], finish: .durableShortBy(frames: 13))
        _ = try over.write(try Self.writeRequest())
        #expect(Self.refusal(MediaWriteFault.self) { try over.finish() } == .ioFailure)
        #expect(over.scriptViolations == 1 && !over.isFinished && over.acceptedFrames == 12)
    }

    @Test
    func io2WriterFinishBeforeAnyWriteIsLegal() throws {
        var durable = try Self.writer([])
        #expect(try durable.finish() == (try MediaWriteFinish.make(acceptedFrames: 0, durableFrames: 0)))
        var zeroShort = try Self.writer([], finish: .durableShortBy(frames: 0))
        #expect(try zeroShort.finish().isPartial == false)
        var oneShort = try Self.writer([], finish: .durableShortBy(frames: 1))
        #expect(Self.refusal(MediaWriteFault.self) { try oneShort.finish() } == .ioFailure)
        #expect(oneShort.scriptViolations == 1)
    }

    @Test
    func io2WriterSecondFinishIsUnavailableAndCountsAViolation() throws {
        var writer = try Self.writer([])
        _ = try writer.finish()
        #expect(Self.refusal(MediaWriteFault.self) { try writer.finish() } == .unavailable)
        #expect(writer.scriptViolations == 1 && writer.isFinished)
        var failing = try Self.writer([], finish: .fail(.diskFull))
        #expect(Self.refusal(MediaWriteFault.self) { try failing.finish() } == .diskFull)
        #expect(!failing.isFinished && failing.scriptViolations == 0)
        #expect(Self.refusal(MediaWriteFault.self) { try failing.finish() } == .unavailable)
        #expect(failing.scriptViolations == 1)
    }

    @Test
    func io2WriterExhaustedScriptIsUnavailableAndCountsAViolation() throws {
        var writer = try Self.writer([])
        let request = try Self.writeRequest()
        #expect(Self.refusal(MediaWriteFault.self) { try writer.write(request) } == .unavailable)
        #expect(writer.scriptViolations == 1 && writer.callCount == 1 && writer.requests == [request])
        #expect(writer.acceptedFrames == 0 && !writer.isFinished)
    }

    @Test
    func io2WriterRecordsTheFirstTwoHundredFiftySixRequestsAndOnlyCountsLaterOnes() throws {
        var writer = try Self.writer(Array(repeating: .pending, count: 256))
        for index in 0..<256 {
            #expect(try writer.write(try Self.writeRequest(frames: 1, start: Int64(index))) == .pending)
        }
        #expect(writer.callCount == 256 && writer.requests.count == 256)
        let extra = try Self.writeRequest(frames: 1, start: 256)
        #expect(Self.refusal(MediaWriteFault.self) { try writer.write(extra) } == .unavailable)
        #expect(writer.callCount == 257 && writer.requests.count == 256)
        #expect(writer.requests.map(\.startFrame) == (0..<256).map(Int64.init))
    }

    @Test
    func io2WriterFinishIsNotCountedAsAWriteCall() throws {
        var writer = try Self.writer([.accept(frames: 1)])
        _ = try writer.write(try Self.writeRequest())
        _ = try writer.finish()
        #expect(writer.callCount == 1 && writer.requests.count == 1)
    }

    @Test
    func io2WriterAcceptedFramesSumEveryScriptedAcceptWithoutClamping() throws {
        let steps = Array(repeating: MediaWriteStep.accept(frames: 65_536), count: 256)
        var writer = try Self.writer(steps)
        let request = try Self.writeRequest(frames: 1)
        for _ in 0..<256 { _ = try writer.write(request) }
        #expect(writer.acceptedFrames == 256 * 65_536)
    }
}
