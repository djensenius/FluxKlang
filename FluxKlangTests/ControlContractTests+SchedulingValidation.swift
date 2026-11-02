import Testing
@testable import FluxKlang

/// Late `nextBoundary` fallback helpers shared by the scheduler musical suites.
extension SchedulerFixture {
    /// A ready request whose late policy falls back to the next musical boundary (transport required).
    func boundaryStamp(_ id: StaticString, _ target: TriggerTarget, grid: Int64 = 960,
                       originHost: UInt64 = 0) -> TriggerStamp {
        let base = stamp(id, target, policy: .nextBoundary(gridTicks: grid), requiring: [Self.transport])
        return TriggerStamp(id: base.id, action: base.action, originHost: .init(ticks: originHost),
                            horizonFrame: base.horizonFrame, requires: base.requires, target: target,
                            latePolicy: base.latePolicy)
    }

    /// Submits and commits with the current witness; returns the single terminal outcome.
    mutating func resolveMusical(_ stamp: TriggerStamp, at frame: Int64) throws -> TriggerOutcome {
        let handle = try submitMusical(stamp)
        #expect(try commitMusical(handle, at: frame) == .completed)
        let outcome = try drainOne(handle)
        #expect(scheduler.pendingCount == 0 && scheduler.musicalSummary?.pinCount == 0)
        return outcome
    }
}

extension ControlContractTests {
    struct SchedulingValidation {
        private static func fired(_ outcome: TriggerOutcome, at frame: Int64,
                                  map: Generation? = .initial) -> TriggerOutcome {
            TriggerOutcome(trigger: outcome.trigger, result: .fired, assignedFrame: frame, frame: frame,
                           musicalMap: map)
        }

        /// V2: each initial target is inside the loop; only the fallback reaches or exceeds its end.
        @Test func everyNextBoundaryFallbackChecksLoopBoundsAndAcceptsTheEnd() throws {
            let loop = try LoopRange(startTicks: 960, endTicks: 1_920)
            for target: TriggerTarget in [.sample(atFrame: 1_500), .musical(atTicks: 960), .grid(ticks: 960)] {
                for (frame, expected): (Int64, Int64) in [(3_001, 4_500), (2_000, 3_000)] {
                    var fixture = try SchedulerFixture(capacity: 1)
                    try fixture.prepareMusical(0, loop: loop)
                    try fixture.observeMusical(.primary, 1_500)
                    let outcome = try fixture.resolveMusical(
                        fixture.boundaryStamp("trg.bound", target, originHost: 750_000), at: frame)
                    #expect(outcome == Self.fired(outcome, at: expected))
                    try outcome.validateMediaShape()
                }
            }
            // A sample target can fall back before the loop start (assigned reference kept), or onto it.
            var before = try SchedulerFixture(capacity: 2)
            try before.prepareMusical(0, loop: loop)
            let outside = try before.resolveMusical(before.boundaryStamp("trg.before", .sample(atFrame: -1)), at: 0)
            #expect(outside == TriggerOutcome(trigger: outside.trigger, result: .dropped, reason: .outsideLoop,
                                              assignedFrame: -1, musicalMap: .initial))
            #expect(throws: TriggerOutcomeValidationError.invalidShape) { try outside.validateMediaShape() }
            let start = try before.resolveMusical(before.boundaryStamp("trg.start", .sample(atFrame: -1)), at: 1)
            #expect(start == Self.fired(start, at: 1_500))
            // ASAP is never late, so nextBoundary must not turn it into a musical fallback.
            var asap = try SchedulerFixture(capacity: 1)
            try asap.prepareMusical(0, loop: loop)
            let now = try asap.resolveMusical(asap.boundaryStamp("trg.asap", .asap), at: 4_000)
            #expect(now == Self.fired(now, at: 4_000, map: nil))
        }

        /// V4: a .drop grid whose initial occurrence crosses the wrap never uses the late fallback.
        @Test func initialGridCrossesWrapWithoutUsingTheLateFallback() throws {
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            for (frame, late): (Int64, Bool) in [(2_500, false), (3_001, true)] {
                var fixture = try SchedulerFixture(capacity: 1)
                try fixture.prepareMusical(0, loop: loop)
                try fixture.observeMusical(.primary, 2_500)
                let stamp = fixture.musicalStamp("trg.grid", .grid(ticks: 1_440), originHost: 1_250_000)
                let handle = try fixture.submitMusical(stamp)
                #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 1, ticks: 0)))
                try fixture.commitMusical(handle, at: frame)
                let outcome = try fixture.drainOne(handle)
                #expect(outcome == (late
                    ? TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .late, assignedFrame: 3_000,
                                     musicalMap: .initial)
                    : Self.fired(outcome, at: 3_000)))
            }
            var empty = try SchedulerFixture(capacity: 1)
            try empty.prepareMusical(0, loop: LoopRange(startTicks: 100, endTicks: 200))
            try empty.observeMusical(.primary, 200)
            let outside = try empty.resolveMusical(
                empty.musicalStamp("trg.empty", .grid(ticks: 1_440), originHost: 100_000), at: 200)
            #expect(outside == TriggerOutcome(trigger: outside.trigger, result: .dropped, reason: .outsideLoop,
                                              musicalMap: .initial))
        }

        /// V9: on-time sample/ASAP ignore the musical witness; a late sample falls back across the wrap.
        @Test func sampleAndASAPIgnoreUnneededMusicalContextAcrossWrap() throws {
            for target: TriggerTarget in [.sample(atFrame: 4_000), .asap] {
                for policy: LatePolicy in [.drop, .nextBoundary(gridTicks: 960)] {
                    var outcomes: [TriggerOutcome] = []
                    for sequence: UInt64? in [1, nil] {
                        var fixture = try SchedulerFixture(capacity: 1)
                        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
                        try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
                        let transport = policy == .drop ? [] : [SchedulerFixture.transport]
                        let handle = try fixture.submitMusical(fixture.stamp("trg.plain", target, policy: policy,
                                                                             requiring: transport))
                        try fixture.commitMusical(handle, at: 3_001, sequence: sequence)
                        outcomes.append(try fixture.drainOne(handle))
                    }
                    #expect(outcomes[0] == outcomes[1])
                    #expect(outcomes[0] == Self.fired(outcomes[0], at: target == .asap ? 3_001 : 4_000, map: nil))
                }
            }
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
            let fallback = try fixture.resolveMusical(fixture.boundaryStamp("trg.late", .sample(atFrame: 1_000)),
                                                      at: 3_001)
            #expect(fallback == Self.fired(fallback, at: 4_500))
        }

        /// V10: the minimum sample frame still falls back to the first boundary at the horizon.
        @Test func fullRangeSampleFallbackSucceedsFromTheMinimumFrame() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let outcome = try fixture.resolveMusical(fixture.boundaryStamp("trg.min", .sample(atFrame: .min)), at: 0)
            #expect(outcome == Self.fired(outcome, at: 0))
            try outcome.validateMediaShape()
        }
    }
}

extension ControlContractTests.SchedulingValidation {
    /// V12: every target kind keeps its occurrence and falls back through the next-pass anchor.
    @Test func wrappedTargetsKeepTheirOccurrenceAndUseTheNextPassAnchor() throws {
        let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
        for target: TriggerTarget in [.sample(atFrame: 3_000), .musical(atTicks: 0), .grid(ticks: 960)] {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: loop)
            try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
            var stamp = fixture.boundaryStamp("trg.wrapped", target, originHost: 1_500_000)
            stamp.loopIteration = 1
            let outcome = try fixture.resolveMusical(stamp, at: 3_001)
            #expect(outcome == Self.fired(outcome, at: 4_500))
        }
        // A covered pass-0 origin keeps its own occurrence; once late it uses the same fallback.
        var old = try SchedulerFixture(capacity: 1)
        try old.prepareMusical(0, loop: loop)
        try old.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
        let oldStamp = old.boundaryStamp("trg.old", .musical(atTicks: 0))
        let handle = try old.submitMusical(oldStamp)
        #expect(old.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
        try old.commitMusical(handle, at: 3_001)
        let oldPass = try old.drainOne(handle)
        #expect(oldPass == Self.fired(oldPass, at: 4_500))
        // Conditional end alias: pass 0's loop end and pass 1's start are the same frame.
        var alias = try SchedulerFixture(capacity: 2)
        try alias.prepareMusical(0, loop: loop)
        let end = try alias.resolveMusical(alias.boundaryStamp("trg.end", .musical(atTicks: 1_920)), at: 3_000)
        #expect(end == Self.fired(end, at: 3_000))
        try alias.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
        var next = alias.boundaryStamp("trg.next", .musical(atTicks: 0), originHost: 1_500_000)
        next.loopIteration = 1
        let start = try alias.resolveMusical(next, at: 3_000)
        #expect(start == Self.fired(start, at: 3_000))
    }

    /// V13: a fallback through a timeline at an old rate is a strict diagnostic, never a frame.
    @Test func musicalRateMismatchIsAStrictFallbackDiagnostic() throws {
        var fixture = try SchedulerFixture(capacity: 2)
        try fixture.prepareMusical(0)
        try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .rateChange(nominalRate: 96_000))
        try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart)
        try fixture.ledger.recordClockRestart(.init(start: fixture.sample(0), host: .init(ticks: 0),
                                                    previousFrame: 999))
        try fixture.observe(0, host: 0)
        let outcome = try fixture.resolveMusical(fixture.boundaryStamp("trg.rate", .sample(atFrame: -1)), at: 10)
        #expect(outcome == TriggerOutcome(trigger: outcome.trigger, result: .dropped, reason: .invalidTiming))
        // A musical target cannot even be admitted against that timeline.
        let before = try fixture.admissionState()
        #expect(throws: TriggerSchedulerError.staleMusicalContext) {
            try fixture.submitMusical(fixture.boundaryStamp("trg.music", .musical(atTicks: 960)))
        }
        #expect(try fixture.admissionState() == before)
    }

    /// A2's forwarder names no musical witness: a late fallback stays the strict diagnostic.
    @Test func forwardedSampleFallbackWithoutMusicalContextStaysDiagnostic() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        let handle = try fixture.submit(fixture.boundaryStamp("trg.forward", .sample(atFrame: -1)))
        try fixture.commit(handle, at: 100)
        #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                               reason: .invalidTiming))
    }

    /// A valid stopped context keeps a late sample's drop; musical stopped policies never apply to samples.
    @Test(arguments: [StoppedPolicy.wait, .immediate, .startTransport])
    func stoppedSampleFallbackKeepsTheLateDrop(policy: StoppedPolicy) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0, running: false)
        var stamp = fixture.boundaryStamp("trg.stopped", .sample(atFrame: -1))
        stamp.stoppedPolicy = policy
        let outcome = try fixture.resolveMusical(stamp, at: 100)
        #expect(outcome == TriggerOutcome(trigger: outcome.trigger, result: .dropped, reason: .late,
                                          assignedFrame: -1))
    }

    /// Refusals before the fallback are non-consuming; past the loop end is a diagnosis. The horizon
    /// can never precede the timeline's latest primary (the clock refuses first), so the fallback's
    /// own uncoveredOrigin refusal is unreachable from commit.
    @Test func fallbackRefusalsAreAtomicAndPastLoopEndIsDiagnosed() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        try fixture.observeMusical(.primary, 2_000)
        let handle = try fixture.submitMusical(fixture.boundaryStamp("trg.uncovered", .sample(atFrame: -1)))
        let before = try fixture.admissionState()
        #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commitMusical(handle, at: 100) }
        #expect(try fixture.admissionState() == before && fixture.scheduler.drain().isEmpty)
        try fixture.commitMusical(handle, at: 2_000)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome == Self.fired(outcome, at: 3_000))
        var past = try SchedulerFixture(capacity: 1)
        try past.prepareMusical(0, ticks: 2_000, loop: LoopRange(startTicks: 0, endTicks: 1_920))
        let diagnosis = try past.resolveMusical(past.boundaryStamp("trg.past", .sample(atFrame: -1)), at: 0)
        #expect(diagnosis == TriggerOutcome(trigger: diagnosis.trigger, result: .dropped, reason: .outsideLoop,
                                            assignedFrame: -1, musicalMap: .initial))
    }

    /// A late `.drop` musical target keeps its projected frame and names the map it was projected through.
    @Test func lateDroppedMusicalTargetNamesItsMap() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        let outcome = try fixture.resolveMusical(
            fixture.musicalStamp("trg.drop", .musical(atTicks: 960), originHost: 0), at: 1_501)
        #expect(outcome == TriggerOutcome(trigger: outcome.trigger, result: .dropped, reason: .late,
                                          assignedFrame: 1_500, musicalMap: .initial))
        try outcome.validateMediaShape()
    }

    /// PROVISIONAL (owner/B2 question): a target missed while running, then a stop before commit, is
    /// resolved by the stopped policy alone. `.immediate` fires at the horizon as if on time (its
    /// lateness disappears) and `.wait` holds an already-missed occurrence. The scheduler deliberately
    /// computes no past-pass late frame while stopped (`project` refuses when stopped); changing this
    /// needs a foundation API. This test pins today's behaviour, not an accepted rule.
    @Test(arguments: [StoppedPolicy.wait, .immediate])
    func missedThenStoppedOccurrenceFollowsTheStoppedPolicy(policy: StoppedPolicy) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        var stamp = fixture.musicalStamp("trg.missed", .musical(atTicks: 960), originHost: 0)
        stamp.stoppedPolicy = policy
        let handle = try fixture.submitMusical(stamp)
        // Frame 1_500 passes while running; the transport stops at frame 2_000 (ticks 1_280).
        try fixture.observeMusical(.running(false), 2_000, ticks: 1_280)
        let decision = try fixture.commitMusical(handle, at: 2_000)
        if policy == .wait {
            #expect(decision == .waitingForTransport)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 960)))
        } else {
            #expect(try decision == .completed && fixture.drainOne(handle) == TriggerOutcome(
                trigger: handle.trigger, result: .fired, assignedFrame: 2_000, frame: 2_000))
        }
    }
}
