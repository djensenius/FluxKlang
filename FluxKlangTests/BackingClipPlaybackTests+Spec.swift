import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension BackingClipPlaybackTests {
    @Test
    func backingSpecAcceptsASingleFrameClipAndKeepsItsFields() throws {
        let spec = try Self.spec(total: 1, underrun: .stopVoice)
        #expect(spec.totalFrames == 1 && spec.loop == nil && spec.loopFrames == nil)
        #expect(spec.action == Self.action && spec.underrun == .stopVoice)
        let looped = try Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 10, endFrame: 40))
        #expect(looped.loop == BackingClipLoop(startFrame: 10, endFrame: 40) && looped.loopFrames == 30)
        #expect(looped.underrun == .silenceAndReport)
    }

    @Test
    func backingSpecRefusesZeroAndNegativeTotalFrames() throws {
        #expect(throws: BackingClipRefusal.totalFramesNotPositive(0)) { try Self.spec(total: 0) }
        #expect(throws: BackingClipRefusal.totalFramesNotPositive(-1)) { try Self.spec(total: -1) }
        #expect(throws: BackingClipRefusal.totalFramesNotPositive(Int64.min)) { try Self.spec(total: Int64.min) }
        #expect(try Self.spec(total: Int64.max).totalFrames == Int64.max)
    }

    @Test
    func backingSpecRefusesEveryTimePolicyExceptFixedRate() throws {
        for policy in [MediaTimePolicy.timeStretch, .tempoFollowing] {
            #expect(throws: BackingClipRefusal.unsupportedTimePolicy(policy)) {
                try BackingClipSpec.make(action: Self.action, totalFrames: 10, loop: nil, timePolicy: policy,
                                         underrun: .silenceAndReport)
            }
        }
        #expect(throws: Never.self) {
            try BackingClipSpec.make(action: Self.action, totalFrames: 10, loop: nil, timePolicy: .fixedRate,
                                     underrun: .stopVoice)
        }
    }

    @Test
    func backingSpecLoopStartBounds() throws {
        #expect(throws: BackingClipRefusal.loopStartNegative(-1)) {
            try Self.spec(loop: BackingClipLoop(startFrame: -1, endFrame: 10))
        }
        #expect(try Self.spec(loop: BackingClipLoop(startFrame: 0, endFrame: 10)).loopFrames == 10)
    }

    @Test
    func backingSpecLoopNeedsAtLeastOneFrame() throws {
        #expect(throws: BackingClipRefusal.loopNotOrdered(start: 5, end: 5)) {
            try Self.spec(loop: BackingClipLoop(startFrame: 5, endFrame: 5))
        }
        #expect(throws: BackingClipRefusal.loopNotOrdered(start: 6, end: 5)) {
            try Self.spec(loop: BackingClipLoop(startFrame: 6, endFrame: 5))
        }
        #expect(try Self.spec(loop: BackingClipLoop(startFrame: 5, endFrame: 6)).loopFrames == 1)
    }

    @Test
    func backingSpecLoopEndBounds() throws {
        #expect(try Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 0, endFrame: 1000)).loopFrames == 1000)
        #expect(throws: BackingClipRefusal.loopEndBeyondClip(end: 1001, totalFrames: 1000)) {
            try Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 0, endFrame: 1001))
        }
        #expect(throws: BackingClipRefusal.loopEndBeyondClip(end: Int64.max, totalFrames: 1000)) {
            try Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 0, endFrame: Int64.max))
        }
    }

    @Test
    func backingSpecRefusalOrderIsTotalThenPolicyThenLoop() throws {
        let badLoop = BackingClipLoop(startFrame: -1, endFrame: -2)
        #expect(throws: BackingClipRefusal.totalFramesNotPositive(0)) {
            try BackingClipSpec.make(action: Self.action, totalFrames: 0, loop: badLoop, timePolicy: .timeStretch,
                                     underrun: .stopVoice)
        }
        #expect(throws: BackingClipRefusal.unsupportedTimePolicy(.timeStretch)) {
            try BackingClipSpec.make(action: Self.action, totalFrames: 10, loop: badLoop, timePolicy: .timeStretch,
                                     underrun: .stopVoice)
        }
        #expect(throws: BackingClipRefusal.loopStartNegative(-1)) {
            try BackingClipSpec.make(action: Self.action, totalFrames: 10, loop: badLoop, timePolicy: .fixedRate,
                                     underrun: .stopVoice)
        }
        #expect(throws: BackingClipRefusal.loopNotOrdered(start: 20, end: 15)) {
            try Self.spec(total: 10, loop: BackingClipLoop(startFrame: 20, endFrame: 15))
        }
    }
}
