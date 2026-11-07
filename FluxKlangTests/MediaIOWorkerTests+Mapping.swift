import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The fault and outcome mapping onto the runtime vocabulary, and the discontinuity builder.
extension MediaIOWorkerTests {
    private static func block() throws -> PrefetchBlock {
        try PrefetchBlock.make(startFrame: 0, frames: 8, sourceGeneration: 1, readGeneration: 1)
    }

    private static func stamp() -> RuntimeSampleStamp {
        RuntimeSampleStamp(clock: 3, generation: 9, frame: 12_345)
    }

    @Test
    func io2MappingEveryReadFaultIsASourceLoss() {
        for fault in MediaReadFault.allCases {
            #expect(Self.name(MediaIOFaultMapping.discontinuityKind(for: fault)) == "sourceLost")
        }
        #expect(MediaReadFault.allCases.count == 3)
    }

    @Test
    func io2MappingWriteFaultsMapToTheTwoStopReasons() {
        let expected: [MediaWriteFault: RuntimeCaptureStopReason] = [
            .diskFull: .diskFull, .unavailable: .deviceLost, .ioFailure: .deviceLost, .interrupted: .deviceLost
        ]
        #expect(MediaWriteFault.allCases.count == 4)
        for fault in MediaWriteFault.allCases {
            let reason = MediaIOFaultMapping.captureStopReason(for: fault)
            #expect(reason == expected[fault])
            let kind = MediaIOFaultMapping.discontinuityKind(for: fault)
            #expect(Self.name(kind) == "captureStopped(\(reason))")
        }
        #expect(TakeStopReason(MediaIOFaultMapping.captureStopReason(for: .diskFull)) == .diskFull)
        #expect(TakeStopReason(MediaIOFaultMapping.captureStopReason(for: .interrupted)) == .deviceLost)
    }

    @Test
    func io2MappingOnlyLatchedLossAndRestoredDeliveryAreDiscontinuities() throws {
        let plain = PrefetchFillDelivery(block: try Self.block(), restoredSource: false, reachedEnd: false)
        let restored = PrefetchFillDelivery(block: try Self.block(), restoredSource: true, reachedEnd: true)
        let cases: [(PrefetchFillOutcome, String)] = [
            (.sourceLost(.unavailable), "sourceLost"),
            (.sourceLost(.ioFailure), "sourceLost"),
            (.delivered(restored), "sourceRestored"),
            (.delivered(plain), "nil"),
            (.endedWithoutData, "nil"),
            (.accumulated(frames: 20), "nil"),
            (.stillPending(polls: 3), "nil"),
            (.retryScheduled(attempt: 2), "nil"),
            (.discardedStale, "nil")
        ]
        for (outcome, expected) in cases {
            #expect(Self.name(MediaIOFaultMapping.discontinuityKind(for: outcome)) == expected)
        }
    }

    @Test
    func io2MappingWriterBackpressureIsOverflow() {
        #expect(Self.name(MediaIOFaultMapping.writerBackpressureKind) == "overflow")
    }

    @Test
    func io2MappingDiscontinuityAcceptsZeroAndTheUInt32Maximum() throws {
        let zero = try MediaIOFaultMapping.discontinuity(.underrun, at: Self.stamp(), stream: 7, frames: 0)
        #expect(zero.frames == 0 && zero.stream == 7 && zero.host == nil)
        #expect(Self.name(zero.kind) == "underrun")
        #expect(zero.sample.clock == 3 && zero.sample.generation == 9 && zero.sample.frame == 12_345)
        let top = try MediaIOFaultMapping.discontinuity(.sourceLost, at: Self.stamp(), stream: 0, frames: 4_294_967_295)
        #expect(top.frames == UInt32.max && top.stream == 0 && top.host == nil)
        #expect(Self.name(top.kind) == "sourceLost")
    }

    @Test
    func io2MappingDiscontinuityRefusesOutOfRangeFramesWithoutClamping() {
        let low = Self.refusal(MediaIOMappingRefusal.self) {
            try MediaIOFaultMapping.discontinuity(.overflow, at: Self.stamp(), stream: 1, frames: -1)
        }
        #expect(low == .framesOutOfRange(frames: -1))
        let high = Self.refusal(MediaIOMappingRefusal.self) {
            try MediaIOFaultMapping.discontinuity(.overflow, at: Self.stamp(), stream: 1, frames: 4_294_967_296)
        }
        #expect(high == .framesOutOfRange(frames: 4_294_967_296))
        let extreme = Self.refusal(MediaIOMappingRefusal.self) {
            try MediaIOFaultMapping.discontinuity(.overflow, at: Self.stamp(), stream: 1, frames: Int64.min)
        }
        #expect(extreme == .framesOutOfRange(frames: Int64.min))
    }
}
