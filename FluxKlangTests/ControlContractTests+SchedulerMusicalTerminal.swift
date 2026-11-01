import Testing
@testable import FluxKlang

/// The shared terminal transaction, pin-aware cancellation, session rotation and the
/// remaining restart/floor/anchor integration findings for musical work (B1 step 5).
/// Absolute targets need no forward choice: every pin here is pass 0, ticks 960 (frame 1_500).
extension ControlContractTests {
    struct SchedulerMusicalTerminal {
        private static let occurrence = SchedulerPendingMusic.pinned(MusicalOccurrence(pass: 0, ticks: 960))

        private static func pin(_ fixture: inout SchedulerFixture, _ id: StaticString,
                                requiring extra: [GenerationKey] = []) throws -> TriggerHandle {
            let handle = try fixture.submitMusical(fixture.stamp(id, .musical(atTicks: 960), requiring: extra))
            #expect(fixture.scheduler.pendingMusic(handle) == occurrence)
            return handle
        }

        private static func fired(_ handle: TriggerHandle, _ fixture: SchedulerFixture) throws -> TriggerOutcome {
            TriggerOutcome(trigger: handle.trigger, result: .fired, assignedFrame: 1_500, frame: 1_500,
                           musicalMap: try #require(fixture.ledger.generation(SchedulerFixture.mapKey)))
        }

        @Test func completionFailurePreservesPinPendingQueueAndClock() throws {
            var fixture = try SchedulerFixture(capacity: 3)
            try fixture.prepareMusical(0)
            let unrelated = try fixture.submit(fixture.stamp("trg.unrelated"))
            try fixture.commit(unrelated, at: 100)
            let handle = try Self.pin(&fixture, "trg.pinned")
            let before = try fixture.admissionState()
            let malformed: [(TriggerOutcome, TriggerSessionError)] = [
                (TriggerOutcome(trigger: handle.trigger, result: .fired), .invalidCompletion),
                (try Self.fired(unrelated, fixture), .mismatchedCompletion)
            ]
            for (outcome, error) in malformed {
                // The REAL session validator rejects the prepared candidate; nothing is published.
                #expect(throws: error) {
                    try fixture.scheduler.completeForTesting(handle, preparedOutcome: outcome)
                }
                #expect(try fixture.admissionState() == before)
                #expect(fixture.scheduler.pendingMusic(handle) == Self.occurrence)
            }
            try fixture.commitMusical(handle, at: 200)
            let queued = fixture.scheduler.drain()
            // The earlier unrelated outcome is neither reordered, consumed nor lost.
            #expect(queued.map(\.handle) == [unrelated, handle])
            #expect(queued.first?.outcome.frame == 100)
            #expect(queued.last?.outcome == (try Self.fired(handle, fixture)))
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
        }

        @Test func diagnosticCompletionFailurePreservesPreparedPinRelease() throws {
            var fixture = try SchedulerFixture(capacity: 2)
            try fixture.prepareMusical(0)
            let handle = try Self.pin(&fixture, "trg.diagnostic")
            let before = try fixture.admissionState()
            let trigger = handle.trigger
            for outcome in [
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .outsideLoop),
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .invalidTiming, assignedFrame: 1_500),
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .invalidTiming, musicalMap: .initial)
            ] {
                #expect(throws: TriggerSessionError.invalidCompletion) {
                    try fixture.scheduler.completeForTesting(handle, preparedOutcome: outcome)
                }
                // Both diagnostics route to completeDiagnostic; the staged pin release is discarded.
                #expect(try fixture.admissionState() == before)
                #expect(before.music?.pinCount == 1)
            }
            // A real missing-witness diagnostic then releases the same pin exactly once.
            try fixture.commitMusical(handle, at: 100, sequence: nil)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: trigger, result: .dropped,
                                                                   reason: .invalidTiming))
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
        }

        /// A non-outsideLoop timeline refusal inside the late `.nextBoundary` fallback (boundary past
        /// Int64.max) propagates non-consumingly: no horizon advance, queue or pending change.
        @Test func boundaryFallbackRefusalIsNonConsuming() throws {
            var fixture = try SchedulerFixture(capacity: 2)
            try fixture.prepareMusical(0)
            let unrelated = try fixture.submit(fixture.stamp("trg.unrelated"))
            try fixture.commit(unrelated, at: 100)
            let handle = try fixture.submitMusical(fixture.boundaryStamp("trg.edge", .sample(atFrame: .max - 1)))
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.overflow) { try fixture.commitMusical(handle, at: .max) }
            #expect(try fixture.admissionState() == before)
            try fixture.commitMusical(handle, at: .max - 1)
            let queued = fixture.scheduler.drain()
            #expect(queued.map(\.handle) == [unrelated, handle] && queued.last?.outcome.frame == .max - 1)
        }

        @Test func terminalSuccessReleasesPinsBeforeDrain() throws {
            var fixture = try SchedulerFixture(capacity: 2)
            try fixture.prepareMusical(0)
            let first = try Self.pin(&fixture, "trg.first")
            let second = try Self.pin(&fixture, "trg.second")
            try fixture.commitMusical(first, at: 100)
            // Released with the enqueue, while the outcome still waits for drain.
            #expect(fixture.scheduler.musicalSummary?.pinCount == 1)
            #expect(fixture.scheduler.reservedOutcomeCount == 2 && fixture.scheduler.pendingCount == 1)
            #expect(fixture.scheduler.pendingMusic(first) == nil)
            #expect(fixture.scheduler.pendingMusic(second) == Self.occurrence)
            #expect(try fixture.drainOne(first) == (try Self.fired(first, fixture)))
        }

        @Test func cancelStaleReleasesPinsWithoutRestartReadiness() throws {
            var fixture = try SchedulerFixture(capacity: 8)
            try fixture.prepareMusical(0)
            let kept = try Self.pin(&fixture, "trg.kept")
            let ids: [StaticString] = ["trg.q", "trg.c", "trg.x", "trg.a", "trg.m", "trg.f"]
            let source = [SchedulerFixture.source]
            var stale: [TriggerHandle] = []
            for (index, id) in ids.enumerated() { // Scrambled IDs, alternately pinned and plain.
                stale.append(try index.isMultiple(of: 2) ? Self.pin(&fixture, id, requiring: source)
                                 : fixture.submit(fixture.stamp(id, requiring: source)))
            }
            let unchanged = try fixture.admissionState()
            #expect(try fixture.scheduler.cancelStale(ledger: fixture.ledger).isEmpty)
            #expect(try fixture.admissionState() == unchanged)
            try fixture.ledger.bump(SchedulerFixture.source, reason: .sourceLost)
            let clock = try fixture.snapshot()
            // Admission order; only stale requests; the current pin and the clock are untouched.
            #expect(try fixture.scheduler.cancelStale(ledger: fixture.ledger) == stale)
            #expect(try fixture.snapshot() == clock)
            #expect(fixture.scheduler.musicalSummary?.pinCount == 1)
            #expect(fixture.scheduler.pendingMusic(kept) == Self.occurrence)
            #expect(fixture.scheduler.drain().map(\.outcome) == stale.map {
                TriggerOutcome(trigger: $0.trigger, result: .cancelled, stale: .generation(source[0]))
            })
            // An incomplete restart blocks firing, yet stale cancellation needs no clock readiness.
            try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
            try #require(fixture.ledger.hasRestartObligations)
            #expect(try fixture.scheduler.cancelStale(ledger: fixture.ledger) == [kept])
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.pendingCount == 0)
            #expect(try fixture.drainOne(kept) == TriggerOutcome(
                trigger: kept.trigger, result: .cancelled, stale: .generation(fixture.ledger.primaryClock)))
        }

        @Test func identityRotationPreservesMusicalHistorySequenceAndHorizon() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
            let used = try fixture.submit(fixture.stamp("trg.used"))
            try fixture.commit(used, at: 3_100)
            _ = try fixture.drainOne(used)
            let music = try #require(fixture.scheduler.musicalSummary)
            let clock = try fixture.snapshot()
            let token = fixture.scheduler.currentToken
            let next = try fixture.scheduler.rotateSession(expected: token)
            #expect(next != token && fixture.scheduler.currentToken == next)
            // Same timeline (never timeline.rotate()), history, sequence and the whole clock.
            #expect(fixture.scheduler.musicalSummary == music && music.observationSequence == 1)
            #expect(try fixture.snapshot() == clock && clock.horizon?.frame == 3_100)
            #expect(try fixture.scheduler.requireMusicalContext(fixture.musicalContext(1)) == music)
            // Only the seen identities were cleared; the horizon still binds.
            let reused = try fixture.submit(fixture.stamp("trg.used"))
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(reused, at: 3_000) }
            try fixture.commit(reused, at: 3_200)
            #expect(try fixture.drainOne(reused).frame == 3_200)
        }

        @Test func remainingPinsPreventSessionRotation() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let handle = try Self.pin(&fixture, "trg.pinned")
            let token = fixture.scheduler.currentToken
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.pinsOutstanding) {
                try fixture.scheduler.rotateSession(expected: token)
            }
            #expect(try fixture.admissionState() == before && fixture.scheduler.currentToken == token)
            try fixture.commitMusical(handle, at: 100)
            // No pins remain; the undrained outcome still keeps the session non-quiescent.
            #expect(throws: TriggerSessionError.notQuiescent) { try fixture.scheduler.rotateSession(expected: token) }
            _ = try fixture.drainOne(handle)
            let next = try fixture.scheduler.rotateSession(expected: token)
            // A stale token is refused before the pin check.
            #expect(throws: TriggerSessionError.staleSession) { try fixture.scheduler.rotateSession(expected: token) }
            #expect(fixture.scheduler.currentToken == next)
        }

        @Test func staleTokenRotationIsRefusedBeforeThePinCheck() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let token = fixture.scheduler.currentToken
            try fixture.scheduler.rotateSession(expected: token)
            _ = try Self.pin(&fixture, "trg.pinned")
            #expect(throws: TriggerSessionError.staleSession) { try fixture.scheduler.rotateSession(expected: token) }
        }

        /// Stale and notReady precedence apply to ready musical work even without a musical witness
        /// and during an incomplete restart; neither becomes invalidTiming. Each releases the pin.
        @Test(arguments: [0, 1, 2])
        func readyMusicalPrecedenceIgnoresMissingContext(stage: Int) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let handle = try Self.pin(&fixture, "trg.pinned", requiring: [SchedulerFixture.source])
            let expected: TriggerOutcome
            switch stage {
            case 0:
                try fixture.ledger.bump(SchedulerFixture.source, reason: .sourceLost)
                expected = TriggerOutcome(trigger: handle.trigger, result: .cancelled,
                                          stale: .generation(SchedulerFixture.source))
            case 1:
                try fixture.readiness.transition(SchedulerFixture.action, to: .invalidated)
                expected = TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .notReady)
            default:
                try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
                try #require(fixture.ledger.hasRestartObligations)
                expected = TriggerOutcome(trigger: handle.trigger, result: .cancelled,
                                          stale: .generation(fixture.ledger.primaryClock))
            }
            #expect(try fixture.commitMusical(handle, at: 100, sequence: nil) == .completed)
            #expect(try fixture.drainOne(handle) == expected)
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
        }

        /// T3: a restart in progress refuses new musical admission atomically, while the old
        /// pinned request is still cancelled (and its pin released) without restart readiness.
        @Test(arguments: [0, 1, 2])
        func finding1183IncompleteRestartRefusesMusicalAdmission(stage: Int) throws {
            var fixture = try SchedulerFixture(capacity: 2)
            try fixture.prepareMusical(0)
            let old = try Self.pin(&fixture, "trg.old")
            try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
            if stage == 1 {
                try fixture.ledger.recordClockRestart(.init(start: fixture.sample(0), host: .init(ticks: 0),
                                                            previousFrame: 0))
            }
            if stage == 2 { try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart) }
            try #require(fixture.ledger.hasRestartObligations)
            let before = try fixture.admissionState()
            #expect(throws: TriggerSchedulerError.staleMusicalContext) {
                try fixture.submitMusical(fixture.stamp("trg.current", .musical(atTicks: 960)))
            }
            #expect(try fixture.admissionState() == before && before.music?.pinCount == 1)
            #expect(try fixture.scheduler.cancelStale(ledger: fixture.ledger) == [old])
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
            #expect(try fixture.drainOne(old).result == .cancelled)
        }

        /// T4: completed obligations but a musical anchor before the restart start is refused
        /// atomically, with no musical coverage created.
        @Test func finding1183MusicalAnchorBeforeTheRestartStartIsRefused() throws {
            var fixture = try SchedulerFixture(capacity: 1, anchored: false)
            try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
            try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart)
            try fixture.ledger.recordClockRestart(.init(start: fixture.sample(1_000), host: .init(ticks: 500_000),
                                                        previousFrame: 0))
            try #require(!fixture.ledger.hasRestartObligations)
            let before = try fixture.admissionState()
            #expect(throws: SchedulerClockError.invalidAnchor) { try fixture.prepareMusical(0) }
            #expect(try fixture.admissionState() == before && before.music == nil)
            #expect(throws: TriggerSchedulerError.musicalContextRequired) {
                try fixture.submitMusical(fixture.musicalStamp("trg.early", .musical(atTicks: 960),
                                                               originHost: 500_000))
            }
            #expect(try fixture.admissionState() == before)
            // The genuine physical restart anchor is accepted; it never creates musical coverage. A first
            // timeline in a restarted generation is restart-derivation semantics (D1, held for #156).
            try fixture.observe(1_000, host: 500_000)
            #expect(try fixture.snapshot().baseline?.anchor.sample.frame == 1_000)
            #expect(fixture.scheduler.musicalSummary == nil)
            #expect(throws: TriggerSchedulerError.musicalContextRequired) {
                try fixture.submitMusical(fixture.musicalStamp("trg.restart", .musical(atTicks: 960),
                                                               originHost: 500_000))
            }
            #expect(fixture.scheduler.reservedOutcomeCount == 0)
        }

        /// T5: a musical observation raises the commit floor; a lower commit keeps the pin.
        @Test func finding1200MusicalObservationRaisesTheCommitFloor() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let handle = try Self.pin(&fixture, "trg.floor")
            try fixture.observeMusical(.musical, 3_000, ticks: 1_920)
            let before = try fixture.admissionState()
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commitMusical(handle, at: 0) }
            #expect(try fixture.admissionState() == before && before.music?.pinCount == 1)
            try fixture.commitMusical(handle, at: 3_000)
            let map = try #require(fixture.ledger.generation(SchedulerFixture.mapKey))
            #expect(try fixture.drainOne(handle) == TriggerOutcome(
                trigger: handle.trigger, result: .dropped, reason: .late, assignedFrame: 1_500, musicalMap: map))
        }

        /// T6: a contradictory observation is refused atomically; the pending pin still projects.
        @Test func finding1227ContradictoryMusicalObservationIsRefused() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let handle = try Self.pin(&fixture, "trg.contradicted")
            let before = try fixture.admissionState()
            // The timeline stage runs first and recognises the drifted anchor.
            #expect(throws: MusicalTimingError.invalidContext) {
                try fixture.observeMusical(.musical, at: fixture.anchor(1_000, host: 0, ticks: 640))
            }
            #expect(try fixture.admissionState() == before)
            try fixture.commitMusical(handle, at: 100)
            #expect(try fixture.drainOne(handle) == (try Self.fired(handle, fixture)))
        }
    }
}
