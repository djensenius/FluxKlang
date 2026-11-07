import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Limits, faults, validated requests, write-finish values and scripts.
extension MediaIOWorkerTests {
    @Test
    func io2LimitsEqualTheRulingLiterals() {
        #expect(MediaIOLimits.maximumRequestFrames == 65_536)
        #expect(MediaIOLimits.maximumRequestFrames == PrefetchPlan.blockFramesRange.upperBound)
        #expect(MediaIOLimits.maximumScriptSteps == 256)
        #expect(MediaIOLimits.maximumRecordedRequests == 256)
        #expect(MediaIOLimits.maximumInFlight == 1)
        #expect(MediaIOLimits.maximumPendingPolls == 8)
        #expect(MediaIOLimits.maximumConsecutiveRetries == 3)
    }

    @Test
    func io2FaultCasesAndRawValuesAreClosedAndOrdered() {
        #expect(MediaReadFault.allCases == [.unavailable, .ioFailure, .interrupted])
        #expect(MediaReadFault.allCases.map(\.rawValue) == ["unavailable", "ioFailure", "interrupted"])
        #expect(MediaWriteFault.allCases == [.unavailable, .ioFailure, .interrupted, .diskFull])
        #expect(MediaWriteFault.allCases.map(\.rawValue) == ["unavailable", "ioFailure", "interrupted", "diskFull"])
    }

    @Test
    func io2ReadRequestFramesAreAcceptedFromOneThroughMaximum() throws {
        let lease = try Self.lease()
        for frames in [1, 65_536] {
            let request = try MediaReadRequest.make(lease: lease, startFrame: 7, frames: frames,
                                                    sourceGeneration: 2, readGeneration: 3)
            #expect(request.frames == frames && request.startFrame == 7 && request.lease == lease)
            #expect(request.sourceGeneration == 2 && request.readGeneration == 3)
        }
        for frames in [0, -1, 65_537] {
            let refused = Self.refusal(MediaIORequestRefusal.self) {
                try MediaReadRequest.make(lease: lease, startFrame: 0, frames: frames,
                                          sourceGeneration: 1, readGeneration: 0)
            }
            #expect(refused == .framesOutOfRange(frames: frames, maximum: 65_536))
        }
    }

    @Test
    func io2ReadRequestStartAndSumBounds() throws {
        let lease = try Self.lease()
        func make(_ start: Int64, _ frames: Int) throws -> MediaReadRequest {
            try MediaReadRequest.make(lease: lease, startFrame: start, frames: frames,
                                      sourceGeneration: 1, readGeneration: 0)
        }
        #expect(try make(0, 1).startFrame == 0)
        #expect(Self.refusal(MediaIORequestRefusal.self) { try make(-1, 1) } == .negativeStartFrame(-1))
        #expect(try make(Int64.max - 4, 4).startFrame == Int64.max - 4)
        #expect(Self.refusal(MediaIORequestRefusal.self) { try make(Int64.max - 4, 5) }
            == .frameOverflow(startFrame: Int64.max - 4, frames: 5))
    }

    @Test
    func io2ReadRequestGenerationBounds() throws {
        let lease = try Self.lease()
        func make(_ source: UInt64, _ read: UInt64) throws -> MediaReadRequest {
            try MediaReadRequest.make(lease: lease, startFrame: 0, frames: 1, sourceGeneration: source,
                                      readGeneration: read)
        }
        #expect(Self.refusal(MediaIORequestRefusal.self) { try make(0, 0) } == .sourceGenerationNotPositive)
        #expect(try make(1, 0).sourceGeneration == 1)
        #expect(try make(1, 0).readGeneration == 0)
        #expect(try make(UInt64.max, UInt64.max).readGeneration == UInt64.max)
    }

    @Test
    func io2RequestChecksRunFramesThenStartThenOverflowThenGeneration() throws {
        let lease = try Self.lease()
        func read(_ start: Int64, _ frames: Int, _ generation: UInt64) -> MediaIORequestRefusal? {
            Self.refusal(MediaIORequestRefusal.self) {
                try MediaReadRequest.make(lease: lease, startFrame: start, frames: frames,
                                          sourceGeneration: generation, readGeneration: 0)
            }
        }
        #expect(read(-1, 0, 0) == .framesOutOfRange(frames: 0, maximum: 65_536))
        #expect(read(-1, 65_537, 1) == .framesOutOfRange(frames: 65_537, maximum: 65_536))
        #expect(read(Int64.max, 65_537, 1) == .framesOutOfRange(frames: 65_537, maximum: 65_536))
        #expect(read(Int64.min, 65_536, 0) == .negativeStartFrame(Int64.min))
        #expect(read(-1, 1, 0) == .negativeStartFrame(-1))
        #expect(read(Int64.max, 1, 0) == .frameOverflow(startFrame: Int64.max, frames: 1))
    }

    @Test
    func io2WriteRequestBoundsAndOrder() throws {
        let lease = try Self.lease()
        func write(_ start: Int64, _ frames: Int) -> Result<MediaWriteRequest, MediaIORequestRefusal> {
            do {
                return .success(try MediaWriteRequest.make(lease: lease, startFrame: start, frames: frames))
            } catch {
                return .failure(error)
            }
        }
        #expect((try? write(0, 1).get())?.frames == 1)
        #expect((try? write(5, 65_536).get())?.startFrame == 5)
        #expect((try? write(0, 1).get())?.lease == lease)
        for frames in [0, -1, 65_537] {
            #expect(write(0, frames) == .failure(.framesOutOfRange(frames: frames, maximum: 65_536)))
        }
        #expect(write(-1, 1) == .failure(.negativeStartFrame(-1)))
        #expect(write(-1, 0) == .failure(.framesOutOfRange(frames: 0, maximum: 65_536)))
        #expect(write(Int64.max - 4, 4).isSuccess)
        #expect(write(Int64.max - 4, 5) == .failure(.frameOverflow(startFrame: Int64.max - 4, frames: 5)))
    }

    @Test
    func io2RequestsCompareAndHashByEveryField() throws {
        let first = try Self.lease()
        let second = try Self.lease()
        let base = try MediaReadRequest.make(lease: first, startFrame: 1, frames: 2, sourceGeneration: 3,
                                             readGeneration: 4)
        let same = try MediaReadRequest.make(lease: first, startFrame: 1, frames: 2, sourceGeneration: 3,
                                             readGeneration: 4)
        #expect(base == same && Set([base, same]).count == 1)
        let others = try [
            MediaReadRequest.make(lease: second, startFrame: 1, frames: 2, sourceGeneration: 3, readGeneration: 4),
            MediaReadRequest.make(lease: first, startFrame: 0, frames: 2, sourceGeneration: 3, readGeneration: 4),
            MediaReadRequest.make(lease: first, startFrame: 1, frames: 1, sourceGeneration: 3, readGeneration: 4),
            MediaReadRequest.make(lease: first, startFrame: 1, frames: 2, sourceGeneration: 2, readGeneration: 4),
            MediaReadRequest.make(lease: first, startFrame: 1, frames: 2, sourceGeneration: 3, readGeneration: 5)
        ]
        for other in others { #expect(other != base) }
        let write = try MediaWriteRequest.make(lease: first, startFrame: 1, frames: 2)
        #expect(write == (try MediaWriteRequest.make(lease: first, startFrame: 1, frames: 2)))
        #expect(write != (try MediaWriteRequest.make(lease: first, startFrame: 1, frames: 3)))
        #expect(write != (try MediaWriteRequest.make(lease: second, startFrame: 1, frames: 2)))
    }

    @Test
    func io2WriteFinishAcceptsDurableUpToAccepted() throws {
        let whole = try MediaWriteFinish.make(acceptedFrames: 10, durableFrames: 10)
        #expect(whole.acceptedFrames == 10 && whole.durableFrames == 10)
        #expect(!whole.isPartial && whole.missingFrames == 0)
        let partial = try MediaWriteFinish.make(acceptedFrames: 10, durableFrames: 9)
        #expect(partial.isPartial && partial.missingFrames == 1)
        let nothing = try MediaWriteFinish.make(acceptedFrames: 0, durableFrames: 0)
        #expect(!nothing.isPartial && nothing.missingFrames == 0)
        let extreme = try MediaWriteFinish.make(acceptedFrames: Int64.max, durableFrames: 0)
        #expect(extreme.isPartial && extreme.missingFrames == Int64.max)
        let refused = Self.refusal(MediaIORequestRefusal.self) {
            try MediaWriteFinish.make(acceptedFrames: 10, durableFrames: 11)
        }
        #expect(refused == .durableExceedsAccepted(durable: 11, accepted: 10))
    }

    @Test
    func io2WriteFinishChecksNegativeAcceptedThenNegativeDurableThenExceeds() {
        func finish(_ accepted: Int64, _ durable: Int64) -> MediaIORequestRefusal? {
            Self.refusal(MediaIORequestRefusal.self) {
                try MediaWriteFinish.make(acceptedFrames: accepted, durableFrames: durable)
            }
        }
        #expect(finish(-1, -2) == .negativeFrames(-1))
        #expect(finish(-2, -1) == .negativeFrames(-2))
        #expect(finish(-1, 5) == .negativeFrames(-1))
        #expect(finish(5, -1) == .negativeFrames(-1))
        #expect(finish(0, 1) == .durableExceedsAccepted(durable: 1, accepted: 0))
    }

    @Test
    func io2ReadScriptAcceptsExactlyTwoHundredFiftySixSteps() throws {
        let full = try MediaReadScript(steps: Array(repeating: .pending, count: 256))
        #expect(full.steps.count == 256)
        let refused = Self.refusal(MediaIOScriptRefusal.self) {
            try MediaReadScript(steps: Array(repeating: .pending, count: 257))
        }
        #expect(refused == .tooManySteps(count: 257, maximum: 256))
        #expect(try MediaReadScript(steps: []).steps.isEmpty)
    }

    @Test
    func io2WriteScriptAcceptsExactlyTwoHundredFiftySixSteps() throws {
        let full = try MediaWriteScript(steps: Array(repeating: .pending, count: 256), finish: .durable)
        #expect(full.steps.count == 256 && full.finish == .durable)
        let refused = Self.refusal(MediaIOScriptRefusal.self) {
            try MediaWriteScript(steps: Array(repeating: .pending, count: 257), finish: .durable)
        }
        #expect(refused == .tooManySteps(count: 257, maximum: 256))
        #expect(try MediaWriteScript(steps: [], finish: .fail(.diskFull)).steps.isEmpty)
    }

    @Test
    func io2ScriptStepFramesAreAcceptedFromZeroThroughMaximum() throws {
        #expect(try MediaReadScript(steps: [.ready(frames: 0), .readyAtEnd(frames: 65_536)]).steps.count == 2)
        #expect(try MediaWriteScript(steps: [.accept(frames: 0), .accept(frames: 65_536)], finish: .durable)
            .steps.count == 2)
        func read(_ step: MediaReadStep) -> MediaIOScriptRefusal? {
            Self.refusal(MediaIOScriptRefusal.self) { try MediaReadScript(steps: [.pending, step]) }
        }
        func write(_ step: MediaWriteStep) -> MediaIOScriptRefusal? {
            Self.refusal(MediaIOScriptRefusal.self) { try MediaWriteScript(steps: [.pending, step], finish: .durable) }
        }
        #expect(read(.ready(frames: -1)) == .negativeFrames(stepIndex: 1, frames: -1))
        #expect(read(.readyAtEnd(frames: -1)) == .negativeFrames(stepIndex: 1, frames: -1))
        #expect(read(.ready(frames: 65_537)) == .framesTooLarge(stepIndex: 1, frames: 65_537, maximum: 65_536))
        #expect(read(.readyAtEnd(frames: 65_537)) == .framesTooLarge(stepIndex: 1, frames: 65_537, maximum: 65_536))
        #expect(write(.accept(frames: -1)) == .negativeFrames(stepIndex: 1, frames: -1))
        #expect(write(.accept(frames: 65_537)) == .framesTooLarge(stepIndex: 1, frames: 65_537, maximum: 65_536))
        #expect(read(.fail(.unavailable)) == nil && write(.fail(.diskFull)) == nil)
    }

    @Test
    func io2ScriptChecksCountThenStepsInIndexOrderThenShortBy() {
        let tooMany = Array(repeating: MediaReadStep.ready(frames: -1), count: 257)
        #expect(Self.refusal(MediaIOScriptRefusal.self) { try MediaReadScript(steps: tooMany) }
            == .tooManySteps(count: 257, maximum: 256))
        let negativeFirst: [MediaReadStep] = [.pending, .ready(frames: -3), .ready(frames: 70_000)]
        let largeFirst: [MediaReadStep] = [.pending, .ready(frames: 70_000), .ready(frames: -3)]
        #expect(Self.refusal(MediaIOScriptRefusal.self) { try MediaReadScript(steps: negativeFirst) }
            == .negativeFrames(stepIndex: 1, frames: -3))
        #expect(Self.refusal(MediaIOScriptRefusal.self) { try MediaReadScript(steps: largeFirst) }
            == .framesTooLarge(stepIndex: 1, frames: 70_000, maximum: 65_536))
        #expect(Self.refusal(MediaIOScriptRefusal.self) {
            try MediaWriteScript(steps: [.accept(frames: -1)], finish: .durableShortBy(frames: -1))
        } == .negativeFrames(stepIndex: 0, frames: -1))
        #expect(Self.refusal(MediaIOScriptRefusal.self) {
            try MediaWriteScript(steps: [.pending], finish: .durableShortBy(frames: -1))
        } == .negativeShortBy(-1))
        #expect(Self.refusal(MediaIOScriptRefusal.self) {
            try MediaWriteScript(steps: Array(repeating: .pending, count: 257), finish: .durableShortBy(frames: -1))
        } == .tooManySteps(count: 257, maximum: 256))
        #expect(Self.refusal(MediaIOScriptRefusal.self) {
            try MediaWriteScript(steps: [], finish: .durableShortBy(frames: 0))
        } == nil)
        #expect(Self.refusal(MediaIOScriptRefusal.self) {
            try MediaWriteScript(steps: [], finish: .durableShortBy(frames: Int64.max))
        } == nil)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { true } else { false }
    }
}
