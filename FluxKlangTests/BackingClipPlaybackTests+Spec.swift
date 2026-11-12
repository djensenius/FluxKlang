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

    // MARK: Start mapping (BJ1)

    static let trigger = TriggerID(validated: "trigger.backing")

    /// A well-formed `joined` outcome: assigned at 0, joined at the horizon `offset`.
    static func joined(_ offset: Int64) -> TriggerOutcome {
        TriggerOutcome(trigger: trigger, result: .joined, assignedFrame: 0, frame: offset, startOffsetFrames: offset)
    }

    static func start(_ outcome: TriggerOutcome, _ spec: BackingClipSpec) throws -> BackingClipStart {
        try BackingClipStart.make(outcome: outcome, spec: spec)
    }

    @Test
    func backingStartGoldenCaseForEveryResult() throws {
        let spec = try Self.spec()
        let stale = StaleDependency.generation(Self.sourceKey)
        let fired = TriggerOutcome(trigger: Self.trigger, result: .fired, assignedFrame: 500, frame: 500)
        let firedLate = TriggerOutcome(trigger: Self.trigger, result: .firedLate, assignedFrame: 500, frame: 540)
        let joined = TriggerOutcome(trigger: Self.trigger, result: .joined, assignedFrame: 500, frame: 540,
                                    startOffsetFrames: 40)
        let cancelled = TriggerOutcome(trigger: Self.trigger, result: .cancelled, stale: stale)
        let rejected = TriggerOutcome(trigger: Self.trigger, result: .rejectedStale, stale: stale)
        let late = TriggerOutcome(trigger: Self.trigger, result: .dropped, reason: .late, assignedFrame: 500)
        let notReady = TriggerOutcome(trigger: Self.trigger, result: .dropped, reason: .notReady)
        #expect(try Self.start(fired, spec) == .start(frame: 0))
        #expect(try Self.start(firedLate, spec) == .start(frame: 0))
        #expect(try Self.start(joined, spec) == .start(frame: 40))
        #expect(try Self.start(cancelled, spec) == .notStarted(.cancelled))
        #expect(try Self.start(rejected, spec) == .notStarted(.rejectedStale))
        #expect(try Self.start(late, spec) == .notStarted(.dropped))
        #expect(try Self.start(notReady, spec) == .notStarted(.dropped))
    }

    @Test
    func backingStartFoldsAJoinIntoTheLoop() throws {
        let spec = try Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 100, endFrame: 300))
        let cases: [(offset: Int64, frame: Int64)] = [
            (1, 1), (99, 99), (100, 100), (299, 299), (300, 100), (301, 101), (499, 299), (500, 100), (2_345, 145)
        ]
        for (offset, frame) in cases {
            #expect(try Self.start(Self.joined(offset), spec) == .start(frame: frame), "offset \(offset)")
        }
        let fromZero = try Self.spec(total: 1000, loop: BackingClipLoop(startFrame: 0, endFrame: 64))
        for (offset, frame) in [(Int64(63), Int64(63)), (64, 0), (65, 1), (640, 0), (641, 1), (1_000, 40)] {
            #expect(try Self.start(Self.joined(offset), fromZero) == .start(frame: frame), "offset \(offset)")
        }
    }

    @Test
    func backingStartWithoutALoopEndsAtAndPastTheClipEnd() throws {
        let spec = try Self.spec(total: 1000)
        #expect(try Self.start(Self.joined(999), spec) == .start(frame: 999))
        #expect(try Self.start(Self.joined(1000), spec) == .ended(startOffsetFrames: 1000))
        #expect(try Self.start(Self.joined(1001), spec) == .ended(startOffsetFrames: 1001))
        #expect(try Self.start(Self.joined(Int64.max), spec) == .ended(startOffsetFrames: Int64.max))
    }

    @Test
    func backingStartHandlesInt64MaxScaleOffsetsWithoutOverflow() throws {
        let huge = Int64.max
        let whole = try Self.spec(total: huge)
        #expect(try Self.start(Self.joined(huge - 1), whole) == .start(frame: huge - 1))
        #expect(try Self.start(Self.joined(huge), whole) == .ended(startOffsetFrames: huge))
        let full = try Self.spec(total: huge, loop: BackingClipLoop(startFrame: 0, endFrame: huge))
        #expect(try Self.start(Self.joined(huge), full) == .start(frame: 0))
        let tail = try Self.spec(total: huge, loop: BackingClipLoop(startFrame: huge - 1, endFrame: huge))
        #expect(try Self.start(Self.joined(huge), tail) == .start(frame: huge - 1))
        let small = BackingClipLoop(startFrame: 3, endFrame: 10)
        let looped = try Self.spec(total: 10, loop: small)
        for offset in [huge, huge - 1, huge / 2, Int64(1) << 62] {
            let expected = Int128(small.startFrame) + (Int128(offset) - Int128(small.endFrame)) % 7
            #expect(try Self.start(Self.joined(offset), looped) == .start(frame: Int64(expected)), "offset \(offset)")
        }
    }

    @Test
    func backingStartRefusesAMalformedOutcomeBeforeMappingIt() throws {
        let spec = try Self.spec()
        let stale = StaleDependency.generation(Self.sourceKey)
        let malformed: [TriggerOutcome] = [
            TriggerOutcome(trigger: Self.trigger, result: .joined, assignedFrame: 0, frame: 40, startOffsetFrames: 39),
            TriggerOutcome(trigger: Self.trigger, result: .joined, assignedFrame: 40, frame: 40),
            TriggerOutcome(trigger: Self.trigger, result: .joined, assignedFrame: 0, frame: 40, startOffsetFrames: -40),
            TriggerOutcome(trigger: Self.trigger, result: .fired, assignedFrame: 0, frame: 0, startOffsetFrames: 1),
            TriggerOutcome(trigger: Self.trigger, result: .fired, assignedFrame: 0, frame: 1),
            TriggerOutcome(trigger: Self.trigger, result: .firedLate, assignedFrame: 0, frame: 0),
            TriggerOutcome(trigger: Self.trigger, result: .fired, assignedFrame: nil, frame: 0),
            TriggerOutcome(trigger: Self.trigger, result: .cancelled),
            TriggerOutcome(trigger: Self.trigger, result: .rejectedStale, stale: stale, startOffsetFrames: 1),
            // Intentional: diagnostic drops (invalidTiming, outsideLoop) are not v1 media outcomes and are refused;
            // the caller treats them as not started. Both scheduler shapes, then a malformed outsideLoop.
            TriggerOutcome(trigger: Self.trigger, result: .dropped, reason: .invalidTiming),
            TriggerOutcome(trigger: Self.trigger, result: .dropped, reason: .outsideLoop, musicalMap: .initial),
            TriggerOutcome(trigger: Self.trigger, result: .dropped, reason: .outsideLoop),
            TriggerOutcome(trigger: Self.trigger, result: .dropped, reason: .late),
            TriggerOutcome(trigger: Self.trigger, result: .dropped, reason: .notReady, startOffsetFrames: 5)
        ]
        for outcome in malformed {
            #expect(throws: BackingClipRefusal.malformedOutcome(.invalidShape)) { try Self.start(outcome, spec) }
        }
    }
}
