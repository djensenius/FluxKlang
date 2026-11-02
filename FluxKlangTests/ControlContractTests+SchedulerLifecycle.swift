import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct SchedulerLifecycle {
        @Test(arguments: [TriggerTarget.grid(ticks: 960), .musical(atTicks: 960)],
              [StoppedPolicy.wait, .immediate, .startTransport])
        func readyMusicalAdmissionRefusesWithoutConsumingIdentityOrFloor(
            target: TriggerTarget, stopped: StoppedPolicy
        ) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            var stamp = fixture.stamp("trg.origin", target, arrival: .max)
            stamp.stoppedPolicy = stopped
            let before = try fixture.snapshot()
            let token = fixture.scheduler.currentToken
            #expect(throws: TriggerSchedulerError.musicalContextRequired) { try fixture.submit(stamp) }
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.currentToken == token && fixture.scheduler.pendingCount == 0)
            #expect(fixture.scheduler.reservedOutcomeCount == 0 && fixture.scheduler.drain().isEmpty)
            // Same ID remains admissible when no musical origin is needed.
            _ = try fixture.submit(fixture.stamp("trg.origin"))
        }

        @Test(arguments: [TriggerTarget.grid(ticks: 960), .musical(atTicks: 960)], [false, true])
        func staleAndUnreadyMusicalAdmissionDoNotResolveTiming(target: TriggerTarget, stale: Bool) throws {
            var fixture = try SchedulerFixture(capacity: 1, anchored: false)
            let stamp = fixture.stamp("trg.no-origin", target, arrival: 10)
            if stale {
                try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange)
            } else {
                fixture.readiness = ActionReadiness()
            }
            let handle = try fixture.submit(stamp)
            #expect(fixture.scheduler.pendingCount == (stale ? 0 : 1))
            if !stale {
                try fixture.prepare()
                try fixture.commit(handle, at: 10)
            }
            let outcome = try fixture.drainOne(handle)
            #expect(outcome.result == (stale ? .rejectedStale : .dropped))
            #expect(outcome.reason == (stale ? nil : .notReady))
            #expect(outcome.stale == (stale ? .generation(SchedulerFixture.context) : nil))
            #expect(outcome.assignedFrame == nil && outcome.musicalMap == nil)
            try outcome.validateMediaShape()
            #expect(try fixture.snapshot().baseline == nil && fixture.snapshot().horizon?.frame == 10)
        }

        @Test(arguments: [GenerationKind.transport, .sampleClock])
        func foreignMusicalCountersAreRejectedBeforeAdmissionAndCannotRaiseTheHorizon(kind: GenerationKind) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            let foreign = GenerationKey(kind, ClockID(validated: "clock.foreign"))
            let invalid = fixture.stamp("trg.foreign", arrival: 999, requiring: [foreign])
            let counters = fixture.ledger.current
            let before = try fixture.snapshot()
            if kind == .transport {
                #expect(throws: GenerationLedgerError.undeclaredMusicalClock(foreign)) {
                    try fixture.ledger.bump(foreign, reason: .locate(ticks: 0))
                }
            } else {
                #expect(throws: GenerationLedgerError.undeclaredSampleClock(foreign)) {
                    try fixture.ledger.bump(foreign, reason: .wake)
                }
            }
            #expect(throws: TriggerValidationError.undeclaredClock(foreign)) { try fixture.submit(invalid) }
            #expect(fixture.ledger.current == counters && fixture.scheduler.reservedOutcomeCount == 0)
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.drain().isEmpty)
            let valid = try fixture.submit(fixture.stamp("trg.foreign"))
            try fixture.commit(valid, at: 10)
            #expect(try fixture.drainOne(valid).frame == 10)
        }

        @Test(arguments: [0, 1, 2], [TriggerTarget.sample(atFrame: 1_000), .asap])
        func finding1183IncompleteRestartMustBlockCommit(stage: Int, target: TriggerTarget) throws {
            var fixture = try SchedulerFixture()
            let old = try fixture.submit(fixture.stamp("trg.old", target))
            try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
            if stage == 1 {
                try fixture.ledger.recordClockRestart(.init(start: fixture.sample(0), host: .init(ticks: 0),
                                                            previousFrame: 0))
            }
            if stage == 2 { try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart) }
            #expect(fixture.ledger.hasRestartObligations)
            let current = try fixture.submit(fixture.stamp("trg.current", target, arrival: 10))
            let before = try fixture.snapshot()
            #expect(throws: SchedulerClockError.restartIncomplete) { try fixture.commit(current, at: 100) }
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.pendingCount == 2 && fixture.scheduler.reservedOutcomeCount == 2)
            #expect(fixture.scheduler.drain().isEmpty)
            try fixture.readiness.transition(SchedulerFixture.action, to: .invalidated)
            // Both precedence paths are usable without completing either restart obligation.
            try fixture.commit(old, at: 10)
            #expect(try fixture.drainOne(old).result == .cancelled)
            try fixture.commit(current, at: 10)
            #expect(try fixture.drainOne(current).reason == .notReady)
            #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 0)
            #expect(try fixture.snapshot().baseline == nil)
        }

        @Test func finding1183CompletedObligationsStillNeedValidRestartAnchor() throws {
            var fixture = try SchedulerFixture(anchored: false)
            try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
            try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart)
            try fixture.ledger.recordClockRestart(.init(start: fixture.sample(1_000), host: .init(ticks: 500_000),
                                                        previousFrame: 0))
            #expect(!fixture.ledger.hasRestartObligations)
            let handle = try fixture.submit(fixture.stamp("trg.restart", arrival: 1_200))
            let before = try fixture.snapshot()
            for (frame, host): (Int64, UInt64) in [(0, 0), (999, 500_000), (1_000, 499_999)] {
                #expect(throws: SchedulerClockError.invalidAnchor) { try fixture.observe(frame, host: host) }
                #expect(try fixture.snapshot() == before)
            }
            #expect(throws: TriggerSchedulerError.musicalContextRequired) {
                try fixture.submit(fixture.stamp("trg.no-coverage", .musical(atTicks: 960), arrival: .max))
            }
            #expect(throws: SchedulerClockError.notReady) { try fixture.commit(handle, at: 1_300) }
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
            #expect(fixture.scheduler.drain().isEmpty)
            try fixture.observe(1_000, host: 500_000)
            #expect(try fixture.snapshot().baseline?.anchor.sample.frame == 1_000)
            #expect(try fixture.snapshot().horizon?.frame == 1_200)
            try fixture.commit(handle, at: 1_200)
            #expect(try fixture.drainOne(handle).frame == 1_200)
        }

        @Test func finding1200AnchorRaisesCommitFloor() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            let handle = try fixture.submit(fixture.stamp("trg.observed"))
            try fixture.observe(3_000, host: 1_500_000)
            let before = try fixture.snapshot()
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(handle, at: 0) }
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
            #expect(fixture.scheduler.drain().isEmpty)
            try fixture.commit(handle, at: 3_000)
            #expect(try fixture.drainOne(handle).frame == 3_000)
        }

        @Test(arguments: [0, 44_100, 48_000, Int.max])
        func commitRejectsInconsistentRatesWithoutConsumingThePendingTrigger(rate: Int) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .rateChange(nominalRate: 96_000))
            try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart)
            try fixture.ledger.recordClockRestart(.init(start: fixture.sample(0), host: .init(ticks: 0),
                                                        previousFrame: 999))
            let handle = try fixture.submit(fixture.stamp("trg.rate"))
            let before = try fixture.snapshot()
            #expect(throws: ClockMapError.invalidRate(rate)) { try fixture.commit(handle, at: 999, rate: rate) }
            #expect(throws: SchedulerClockError.notReady) { try fixture.commit(handle, at: 10) }
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
            #expect(fixture.scheduler.drain().isEmpty)
            try fixture.observe(0, host: 0)
            try fixture.commit(handle, at: 10)
            #expect(try fixture.drainOne(handle).frame == 10)
            // Needed musical-rate mismatch remains B1's diagnostic assertion.
        }
    }
}

extension ControlContractTests.SchedulerLifecycle {
    @Test(arguments: [TriggerTarget.sample(atFrame: 4_000), .asap],
          [LatePolicy.drop, .nextBoundary(gridTicks: 960)])
    func controlsIgnoreIrrelevantMusicalDataAndPreserveReadinessPrecedence(
        target: TriggerTarget, policy: LatePolicy
    ) throws {
        let transport = policy == .drop ? [] : [SchedulerFixture.transport]
        var fixture = try SchedulerFixture(capacity: 1)
        let handle = try fixture.submit(fixture.stamp("trg.unused", target, policy: policy, requiring: transport))
        let malformed = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: .min, loopIteration: .max)
        let before = try fixture.snapshot()
        #expect(throws: SchedulerClockError.invalidAnchor) {
            try fixture.observe(1_000, host: 0, musical: malformed)
        }
        #expect(try fixture.snapshot() == before)
        try fixture.observe(3_000, host: 1_500_000, musical: malformed)
        #expect(try fixture.snapshot().latestAnchor?.musical == nil)
        try fixture.commit(handle, at: 3_001)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome.result == .fired && outcome.frame == (target == .asap ? 3_001 : 4_000))
        #expect(outcome.musicalMap == nil)
        try outcome.validateMediaShape()
        for initiallyReady in [false, true] {
            var unready = try SchedulerFixture(capacity: 1, anchored: false)
            if !initiallyReady { unready.readiness = ActionReadiness() }
            let pending = try unready.submit(unready.stamp("trg.readiness", target,
                                                           policy: policy, requiring: transport))
            if initiallyReady { try unready.readiness.transition(SchedulerFixture.action, to: .invalidated) }
            try unready.prepare()
            try unready.commit(pending, at: 100)
            #expect(try unready.drainOne(pending).reason == .notReady)
            #expect(try unready.snapshot().baseline == nil)
        }
    }

    @Test(arguments: [false, true])
    func readinessDependenciesMustBeCurrentAtSubmissionAndCommit(changeBeforeSubmission: Bool) throws {
        var fixture = try SchedulerFixture(capacity: 1, anchored: false)
        if changeBeforeSubmission { try fixture.ledger.bump(SchedulerFixture.source, reason: .sourceLost) }
        let handle = try fixture.submit(fixture.stamp("trg.preparation"))
        if changeBeforeSubmission {
            fixture.readiness.generationChanged(SchedulerFixture.source)
            try fixture.prepare()
        } else {
            // No generationChanged notification: isCurrent must still catch stale preparation.
            try fixture.ledger.bump(SchedulerFixture.source, reason: .sourceLost)
        }
        try fixture.commit(handle, at: 100)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .notReady))
        #expect(try fixture.snapshot().baseline == nil)
    }

    @Test(arguments: [TriggerTarget.grid(ticks: 960), .musical(atTicks: 960)])
    func staleReadyMusicalPreparationAdmitsThenDropsWithoutOrigin(target: TriggerTarget) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        let before = try fixture.snapshot()
        try fixture.ledger.bump(SchedulerFixture.source, reason: .sourceLost)
        // P3: no generationChanged notification; readyEntry exists but preparation is stale.
        #expect(fixture.readiness.state(SchedulerFixture.action) == .ready)
        #expect(fixture.readiness.readyEntry(SchedulerFixture.action) != nil)
        #expect(!fixture.readiness.isCurrent(SchedulerFixture.action, ledger: fixture.ledger))
        let stamp = fixture.stamp("trg.stale-ready-music", target, arrival: 40)
        #expect(stamp.requires.allSatisfy(fixture.ledger.isCurrent))
        // Admission must not throw musicalContextRequired for this captured-unready action.
        let handle = try fixture.submit(stamp)
        #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
        #expect(fixture.scheduler.drain().isEmpty)
        let admitted = try fixture.snapshot()
        #expect(admitted.baseline == before.baseline && admitted.latestAnchor == before.latestAnchor)
        #expect(admitted.generation == before.generation && admitted.nominalRate == before.nominalRate)
        #expect(admitted.horizon == (try fixture.sample(40)))
        #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(handle, at: 39) }
        #expect(try fixture.snapshot() == admitted)
        #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
        #expect(fixture.scheduler.drain().isEmpty)
        try fixture.commit(handle, at: 40)
        #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 1)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .notReady))
        try outcome.validateMediaShape()
        #expect(fixture.scheduler.reservedOutcomeCount == 0 && fixture.scheduler.drain().isEmpty)
        #expect(try fixture.snapshot() == admitted)
    }

    @Test(arguments: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
          [LatePolicy.fireLate(maxLatenessMs: 1), .joinInProgress(maxLatenessMs: 1)])
    func latenessLimitsUseExactMillisecondsWithoutNarrowing(rate: Int, policy: LatePolicy) throws {
        let limit = Int64(rate / 1_000)
        for lateness in [0, limit, limit + 1] {
            var fixture = try SchedulerFixture(capacity: 1, frame: .min, rate: rate)
            let handle = try fixture.submit(fixture.stamp("trg.limit", .sample(atFrame: .min),
                                                          policy: policy, arrival: .min))
            try fixture.commit(handle, at: Int64.min + lateness)
            let outcome = try fixture.drainOne(handle)
            let joined = policy == .joinInProgress(maxLatenessMs: 1)
            let expected: OutcomeResult = lateness == 0 ? .fired : (joined ? .joined : .firedLate)
            #expect(outcome.result == (lateness > limit ? .dropped : expected))
            #expect(outcome.reason == (lateness > limit ? .late : nil))
            #expect(outcome.startOffsetFrames == (joined && lateness <= limit ? lateness : 0))
            try outcome.validateMediaShape()
        }
    }

    /// The forwarder names no musical witness, so every stopped label yields the same missing-music
    /// diagnostic; injected completion failures belong to the shared terminal transaction's tests.
    @Test(arguments: [StoppedPolicy.wait, .immediate, .startTransport])
    func missingMusicDiagnosticSharesTheCanonicalQueue(stopped: StoppedPolicy) throws {
        var fixture = try SchedulerFixture(capacity: 2)
        let bare = fixture.stamp("trg.diagnostic", .sample(atFrame: .min), policy: .nextBoundary(gridTicks: 960))
        #expect(throws: TriggerValidationError.nextBoundaryWithoutTransport) { try fixture.submit(bare) }
        #expect(fixture.scheduler.reservedOutcomeCount == 0)
        let first = try fixture.submit(fixture.stamp("trg.canonical"))
        var stamp = fixture.stamp("trg.diagnostic", .sample(atFrame: .min),
                                  policy: .nextBoundary(gridTicks: 960), requiring: [SchedulerFixture.transport])
        stamp.stoppedPolicy = stopped
        let diagnostic = try fixture.submit(stamp)
        try fixture.commit(diagnostic, at: 100)
        #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 2)
        try fixture.commit(first, at: 100)
        #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 2)
        let before = try fixture.snapshot()
        for handle in [diagnostic, first] {
            #expect(throws: TriggerSessionError.notPending) { try fixture.commit(handle, at: .max, rate: 0) }
        }
        #expect(throws: TriggerSessionError.outcomeCapacity) { try fixture.submit(fixture.stamp("trg.extra")) }
        #expect(try fixture.snapshot() == before)
        let queued = fixture.scheduler.drain()
        #expect(queued.map(\.handle) == [diagnostic, first])
        let expected = TriggerOutcome(trigger: diagnostic.trigger, result: .dropped, reason: .invalidTiming)
        #expect(queued.first?.outcome == expected)
        #expect(throws: TriggerOutcomeValidationError.invalidShape) { try expected.validateMediaShape() }
        try #require(queued.last).outcome.validateMediaShape()
        #expect(fixture.scheduler.reservedOutcomeCount == 0 && fixture.scheduler.drain().isEmpty)
        #expect(throws: TriggerSessionError.notPending) { try fixture.commit(diagnostic, at: .max) }
        #expect(throws: TriggerSessionError.duplicateID) { try fixture.submit(stamp) }
        let extra = try fixture.submit(fixture.stamp("trg.extra"))
        try fixture.commit(extra, at: 100)
        #expect(try fixture.drainOne(extra).result == .fired)
    }

    @Test func invalidCommitIdentityAndHorizonAreAtomic() throws {
        var fixture = try SchedulerFixture(capacity: 2)
        let handle = try fixture.submit(fixture.stamp("trg.identity", arrival: 10))
        var other = try SchedulerFixture(capacity: 1)
        let foreignHandle = try other.submit(other.stamp("trg.identity"))
        let before = try fixture.snapshot()
        #expect(throws: TriggerSessionError.staleSession) { try fixture.commit(foreignHandle, at: .max, rate: 0) }
        let foreign = SampleStamp(clock: ClockID(validated: "smp.foreign"), generation: .initial, frame: 999)
        #expect(throws: SchedulerClockError.primaryClockMismatch) {
            try fixture.scheduler.commit(handle, at: foreign, nominalRate: 48_000,
                                         ledger: fixture.ledger, readiness: fixture.readiness)
        }
        #expect(throws: ClockMapError.staleSampleGeneration) {
            try fixture.commit(handle, at: 999, generation: Generation.initial.next())
        }
        #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(handle, at: 9) }
        let foreignLedger = try GenerationLedger(primaryClock: foreign.clock, musicalClock: nil, nominalRate: 48_000)
        #expect(throws: TriggerSessionError.staleSession) {
            try fixture.scheduler.submit(fixture.stamp("trg.foreign-session", arrival: .max),
                session: other.scheduler.currentToken, ledger: fixture.ledger, readiness: fixture.readiness)
        }
        #expect(throws: SchedulerClockError.primaryClockMismatch) {
            try fixture.scheduler.submit(fixture.stamp("trg.foreign-ledger", arrival: .max),
                session: fixture.scheduler.currentToken, ledger: foreignLedger, readiness: fixture.readiness)
        }
        #expect(throws: SchedulerClockError.primaryClockMismatch) {
            try fixture.scheduler.commit(handle, at: fixture.sample(999), nominalRate: 48_000,
                                         ledger: foreignLedger, readiness: fixture.readiness)
        }
        #expect(try fixture.snapshot() == before)
        #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
        #expect(fixture.scheduler.drain().isEmpty)
        try fixture.commit(handle, at: 10)
        #expect(try fixture.drainOne(handle).frame == 10)
    }
}

extension ControlContractTests.SchedulerLifecycle {
    @Test(arguments: [TriggerTarget.sample(atFrame: 4_000), .asap])
    func firstPhysicalAnchorIsRequiredBeforeFiring(target: TriggerTarget) throws {
        var fixture = try SchedulerFixture(capacity: 1, anchored: false)
        let handle = try fixture.submit(fixture.stamp("trg.first-anchor", target, arrival: 40))
        let before = try fixture.snapshot()
        #expect(before.baseline == nil && before.latestAnchor == nil && before.horizon?.frame == 40)
        #expect(throws: SchedulerClockError.notReady) { try fixture.commit(handle, at: 100) }
        #expect(try fixture.snapshot() == before)
        #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
        #expect(fixture.scheduler.drain().isEmpty)
        try fixture.observe(0, host: 0)
        #expect(try fixture.snapshot().horizon?.frame == 40)
        try fixture.commit(handle, at: 40)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome.result == .fired && outcome.frame == (target == .asap ? 40 : 4_000))
        try outcome.validateMediaShape()
    }

    @Test(arguments: [false, true])
    func invalidHorizonPrecedesCancellationAndNotReady(cancelled: Bool) throws {
        var fixture = try SchedulerFixture(capacity: 1, anchored: false)
        fixture.readiness = ActionReadiness()
        let handle = try fixture.submit(fixture.stamp("trg.precedence", arrival: 10))
        if cancelled { try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange) }
        let before = try fixture.snapshot()
        #expect(throws: ClockMapError.invalidRate(96_000)) { try fixture.commit(handle, at: 999, rate: 96_000) }
        #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(handle, at: 9) }
        #expect(try fixture.snapshot() == before)
        #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
        #expect(fixture.scheduler.drain().isEmpty)
        try fixture.commit(handle, at: 10)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome.result == (cancelled ? .cancelled : .dropped))
        #expect(outcome.reason == (cancelled ? nil : .notReady))
        try outcome.validateMediaShape()
    }

    @Test func identityRotationPreservesClockHistoryAndHorizon() throws {
        var fixture = try SchedulerFixture(capacity: 1, frame: 123_456, host: 1_000_000)
        try fixture.observe(171_552, host: 25_000_000)
        let token = fixture.scheduler.currentToken
        let stamp = fixture.stamp("trg.rotate", arrival: 171_752)
        let handle = try fixture.submit(stamp)
        let pending = try fixture.snapshot()
        #expect(throws: TriggerSessionError.notQuiescent) { try fixture.scheduler.rotateSession(expected: token) }
        #expect(try fixture.snapshot() == pending)
        try fixture.commit(handle, at: 171_900)
        let completed = try fixture.snapshot()
        #expect(throws: TriggerSessionError.notQuiescent) { try fixture.scheduler.rotateSession(expected: token) }
        #expect(try fixture.snapshot() == completed)
        #expect(fixture.scheduler.currentToken == token)
        _ = try fixture.drainOne(handle)
        #expect(throws: TriggerSessionError.duplicateID) { try fixture.submit(stamp) }
        let next = try fixture.scheduler.rotateSession(expected: token)
        #expect(next != token && fixture.scheduler.currentToken == next)
        #expect(try fixture.snapshot() == completed)
        #expect(throws: TriggerSessionError.staleSession) { try fixture.scheduler.rotateSession(expected: token) }
        #expect(throws: TriggerSessionError.staleSession) {
            try fixture.scheduler.submit(stamp, session: token, ledger: fixture.ledger, readiness: fixture.readiness)
        }
        #expect(throws: TriggerSessionError.staleSession) { try fixture.commit(handle, at: .max) }
        let reused = try fixture.submit(stamp)
        #expect(reused != handle && reused.trigger == handle.trigger)
        #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(reused, at: 171_899) }
        // Agrees with rolling latest, NOT the genuine baseline. Rotation must not rebase.
        #expect(throws: SchedulerClockError.invalidAnchor) { try fixture.observe(219_648, host: 49_000_000) }
        #expect(try fixture.snapshot() == completed)
        #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
        try fixture.commit(reused, at: 171_900)
        #expect(try fixture.drainOne(reused).frame == 171_900)
    }

    @Test func seenIDsSurviveDrainAndGenerationChanges() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        let stamp = fixture.stamp("trg.seen")
        let token = fixture.scheduler.currentToken
        let handle = try fixture.submit(stamp)
        try fixture.commit(handle, at: 0)
        _ = try fixture.drainOne(handle)
        try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange)
        #expect(throws: TriggerSessionError.duplicateID) { try fixture.submit(stamp) }
        try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
        #expect(throws: TriggerSessionError.duplicateID) { try fixture.submit(stamp) }
        #expect(fixture.scheduler.currentToken == token && fixture.scheduler.reservedOutcomeCount == 0)
        #expect(try fixture.snapshot().horizon == nil && fixture.scheduler.drain().isEmpty)
        // Accepted TriggerLifecycle owns the 65,536-ID exhaustion loop; no second loop.
    }
}
