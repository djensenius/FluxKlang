import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct MusicalScheduling {
        @Test(arguments: [0, 1])
        func musicalHistoryRefusalsConsumeNeitherIdentityFloorNorOutcome(retro: Int) throws {
            var fixture = try SchedulerFixture(capacity: 4)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 3), history: 2)
            let stored = try fixture.submitMusical(fixture.musicalStamp("trg.stored", .musical(atTicks: 0),
                                                                        originHost: 0))
            #expect(fixture.scheduler.pendingMusic(stored) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
            for pass: UInt32 in 1...3 {
                try fixture.observeMusical(.wrap, Int64(pass) * 5, ticks: 0, pass: pass)
            }
            try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
            try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 900_000)), 15)
            try fixture.observeMusical(.primary, 16)
            let before = try fixture.admissionState()
            #expect(before.music?.pinCount == 1 && before.clock.horizon?.frame == 16)
            // Internal gap: the stored pass-0 pin and retained passes 2/3 surround an evicted pass 1.
            // Zero retroactive tolerance must refuse too, never substitute a farther forward occurrence.
            var gapped = fixture.musicalStamp("trg.music", .grid(ticks: 1), originHost: 8_000,
                                              policy: retro > 0 ? .fireLate(maxLatenessMs: 1) : .drop, arrival: 20)
            gapped.retroactiveMs = retro
            gapped.loopIteration = 3
            #expect(throws: MusicalTimingError.historyUnavailable) { try fixture.submitMusical(gapped) }
            #expect(try fixture.admissionState() == before)
            // Evicted origin: frame 11 is no longer retained history.
            let evicted = fixture.musicalStamp("trg.music", .grid(ticks: 1), originHost: 5_500, arrival: 20)
            #expect(throws: MusicalTimingError.uncoveredOrigin) { try fixture.submitMusical(evicted) }
            #expect(try fixture.admissionState() == before)
            #expect(fixture.scheduler.drain().isEmpty)
            // Neither refusal consumed the identity, the arrival floor or an outcome slot.
            let handle = try fixture.submit(fixture.stamp("trg.music", arrival: 20))
            #expect(try fixture.snapshot().horizon?.frame == 20 && fixture.scheduler.reservedOutcomeCount == 2)
            try fixture.commit(handle, at: 20)
            #expect(try fixture.drainOne(handle).frame == 20)
        }

        @Test func provisionalPinIsReleasedWhenSessionReservationFails() throws {
            var fixture = try SchedulerFixture(capacity: 2)
            try fixture.prepareMusical(0)
            try fixture.observeMusical(.primary, 1_500)
            let foreign = try SchedulerFixture(capacity: 1).scheduler.currentToken
            let stamp = fixture.musicalStamp("trg.pin", .musical(atTicks: 960), originHost: 375_000, arrival: 1_600)
            let before = try fixture.admissionState()
            // Preparation succeeds, then the REAL session reservation refuses the foreign token.
            #expect(throws: TriggerSessionError.staleSession) {
                try fixture.scheduler.admit(stamp, preflight: fixture.scheduler.currentToken, reservation: foreign,
                                            context: fixture.musicalContext(1))
            }
            #expect(try fixture.admissionState() == before && before.music?.pinCount == 0)
            #expect(fixture.scheduler.drain().isEmpty)
            let handle = try fixture.submitMusical(stamp)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 960)))
            #expect(fixture.scheduler.musicalSummary?.pinCount == 1)
            // Terminal cancellation releases the pin with the enqueue, before any drain.
            try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange)
            try fixture.commit(handle, at: 1_600)
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.reservedOutcomeCount == 1)
            #expect(fixture.scheduler.pendingMusic(handle) == nil)
            #expect(try fixture.drainOne(handle).result == .cancelled)
        }

        @Test(arguments: [false, true])
        func pinlessOutsideLoopAdmissionStillDefersTerminalPrecedence(cancelled: Bool) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            try fixture.observeMusical(.primary, 1_500)
            let handle = try fixture.submitMusical(fixture.musicalStamp("trg.outside", .musical(atTicks: 3_000),
                                                                        originHost: 375_000, arrival: 1_500))
            #expect(fixture.scheduler.pendingMusic(handle) == .outsideLoop)
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
            #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
            #expect(fixture.scheduler.drain().isEmpty)
            if cancelled {
                try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange)
            } else {
                try fixture.readiness.transition(SchedulerFixture.action, to: .invalidated)
            }
            try fixture.commit(handle, at: 1_500)
            let outcome = try fixture.drainOne(handle)
            let stale = StaleDependency.generation(SchedulerFixture.context)
            let expected = cancelled
                ? TriggerOutcome(trigger: handle.trigger, result: .cancelled, stale: stale)
                : TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .notReady)
            #expect(outcome == expected)
            try outcome.validateMediaShape()
        }

        @Test(arguments: [Int64(1_920), .max])
        func mismatchedMusicalPassIsRefusedBeforeExtrapolation(end: Int64) throws {
            // With end .max, extrapolating to pass UInt32.max - 1 would overflow even Int128
            // (Int64.max * 500_000 * 48_000 * (UInt32.max - 1)); the pass check must come first.
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: end))
            var stamp = fixture.musicalStamp("trg.pass", .musical(atTicks: 0), originHost: 0, arrival: 10)
            stamp.loopIteration = .max
            let before = try fixture.admissionState()
            #expect(throws: TriggerSchedulerError.musicalPassMismatch) { try fixture.submitMusical(stamp) }
            #expect(try fixture.admissionState() == before)
            #expect(fixture.scheduler.drain().isEmpty)
            stamp.loopIteration = 0
            let handle = try fixture.submitMusical(stamp)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
        }

        @Test(arguments: [Int64(1_920), .max])
        func missingOriginContextCannotInventAFutureMusicalPass(end: Int64) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: end))
            // Physical-only progress is not musical origin coverage.
            try fixture.observe(1_000, host: 500_000)
            var stamp = fixture.musicalStamp("trg.future", .musical(atTicks: 0), originHost: 500_000, arrival: 1_200)
            stamp.loopIteration = .max
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.uncoveredOrigin) { try fixture.submitMusical(stamp) }
            #expect(try fixture.admissionState() == before && before.music?.pinCount == 0)
            #expect(fixture.scheduler.drain().isEmpty)
        }

        /// T2's missing-origin branch; the valid-origin firing branch follows with commit projection.
        @Test func finding1170ReadyAbsoluteNeedsOriginContext() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            let stamp = fixture.musicalStamp("trg.1170", .musical(atTicks: 960), originHost: 0, arrival: 3_000)
            let unprepared = try fixture.admissionState()
            #expect(throws: TriggerSchedulerError.musicalContextRequired) { try fixture.submitMusical(stamp) }
            #expect(try fixture.admissionState() == unprepared)
            try fixture.prepareMusical(3_000)
            let prepared = try fixture.admissionState()
            // A2's forwarding signature names no musical sequence: missing context, not a fallback.
            #expect(throws: TriggerSchedulerError.musicalContextRequired) { try fixture.submit(stamp) }
            // The origin precedes the first musical anchor.
            #expect(throws: MusicalTimingError.uncoveredOrigin) { try fixture.submitMusical(stamp) }
            #expect(try fixture.admissionState() == prepared)
            #expect(fixture.scheduler.drain().isEmpty)
            // Valid branch: a covered pass-0 origin keeps assigned 1_500 across the wrap and dispatches late.
            var valid = try SchedulerFixture(capacity: 1)
            try valid.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            let handle = try valid.submitMusical(valid.musicalStamp("trg.1170", .musical(atTicks: 960), originHost: 0,
                                                                    policy: .fireLate(maxLatenessMs: 100)))
            try valid.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
            #expect(try valid.commitMusical(handle, at: 3_001) == .completed)
            let outcome = try valid.drainOne(handle)
            #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .firedLate, assignedFrame: 1_500,
                                              frame: 3_001, musicalMap: .initial))
            try outcome.validateMediaShape()
            #expect(valid.scheduler.musicalSummary?.pinCount == 0)
        }
    }
}

extension ControlContractTests.MusicalScheduling {
    @Test func stoppedTransportPolicies() throws {
        var fixture = try SchedulerFixture(capacity: 3)
        try fixture.prepareMusical(0)
        try fixture.observeMusical(.primary, 1_000)
        var waiting = fixture.musicalStamp("trg.wait", .grid(ticks: 15_360), originHost: 500,
                                           policy: .nextBoundary(gridTicks: nil))
        waiting.stoppedPolicy = .wait
        var immediate = fixture.musicalStamp("trg.now", .grid(ticks: 15_360), originHost: 500)
        immediate.stoppedPolicy = .immediate
        var starting = fixture.musicalStamp("trg.start", .musical(atTicks: 0), originHost: 0)
        starting.stoppedPolicy = .startTransport
        let handles = try [waiting, immediate, starting].map { try fixture.submitMusical($0) }
        try fixture.observeMusical(.running(false), 1_000, ticks: 640)
        #expect(try fixture.commitMusical(handles[0], at: 1_000) == .waitingForTransport)
        #expect(fixture.scheduler.pendingMusic(handles[0]) == .pinned(MusicalOccurrence(pass: 0, ticks: 15_360)))
        #expect(fixture.scheduler.drain().isEmpty && fixture.scheduler.musicalSummary?.pinCount == 3)
        #expect(try fixture.commitMusical(handles[1], at: 1_000) == .completed)
        #expect(try fixture.drainOne(handles[1]) == TriggerOutcome(trigger: handles[1].trigger, result: .fired,
                                                                   assignedFrame: 1_000, frame: 1_000))
        // startTransport is feedback; its single terminal outcome is still delivered only by drain.
        #expect(try fixture.commitMusical(handles[2], at: 1_000) == .startTransport)
        #expect(try fixture.drainOne(handles[2]) == TriggerOutcome(trigger: handles[2].trigger, result: .fired,
                                                                   assignedFrame: 1_000, frame: 1_000))
        try fixture.observeMusical(.running(true), 2_000, ticks: 640)
        #expect(try fixture.commitMusical(handles[0], at: 2_000) == .completed)
        #expect(try fixture.drainOne(handles[0]) == TriggerOutcome(trigger: handles[0].trigger, result: .fired,
                                                                   assignedFrame: 25_000, frame: 25_000,
                                                                   musicalMap: .initial))
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
    }

    /// A stopped transport never wraps, so the wrap variant exists only for `.wait`, which commits after
    /// the restart (4 cases, not the plan's 3x2 matrix whose immediate/startTransport wraps were inert).
    @Test(arguments: [(StoppedPolicy.wait, false), (.wait, true), (.immediate, false), (.startTransport, false)])
    func stoppedAtSubmissionDoesNotAdvanceTheMusicalPosition(policy: StoppedPolicy, wrapBeforeCommit: Bool) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920), running: false)
        try fixture.observeMusical(.primary, 5_000)
        var stamp = fixture.musicalStamp("trg.stopped", .grid(ticks: 1_440), originHost: 2_500_000,
                                         policy: .fireLate(maxLatenessMs: 100), arrival: 5_000)
        stamp.stoppedPolicy = policy
        let handle = try fixture.submitMusical(stamp)
        // The held position is ticks 0, not an extrapolation over 5_000 stopped frames.
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
        let decision = try fixture.commitMusical(handle, at: 5_000)
        let fired = TriggerOutcome(trigger: handle.trigger, result: .fired, assignedFrame: 5_000, frame: 5_000)
        switch policy {
        case .immediate:
            #expect(try decision == .completed && fixture.drainOne(handle) == fired)
        case .startTransport:
            #expect(try decision == .startTransport && fixture.drainOne(handle) == fired)
        case .wait:
            #expect(decision == .waitingForTransport && fixture.scheduler.pendingMusic(handle) != nil)
            #expect(try fixture.snapshot().horizon?.frame == 5_000)
            // Waiting publishes the advanced horizon as a floor; a later commit cannot regress it.
            #expect(try fixture.commitMusical(handle, at: 5_500) == .waitingForTransport)
            let waited = try fixture.admissionState()
            #expect(waited.clock.horizon?.frame == 5_500)
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commitMusical(handle, at: 5_400) }
            #expect(try fixture.admissionState() == waited && fixture.scheduler.drain().isEmpty)
            try fixture.observeMusical(.running(true), 6_000, ticks: 0)
            if wrapBeforeCommit { try fixture.observeMusical(.wrap, 9_000, ticks: 0, pass: 1) }
            let commitFrame: Int64 = wrapBeforeCommit ? 9_001 : 6_000
            #expect(try fixture.commitMusical(handle, at: commitFrame) == .completed)
            let result = try fixture.drainOne(handle)
            #expect(result.result == (wrapBeforeCommit ? .firedLate : .fired))
            #expect(result.assignedFrame == 6_000 && result.frame == commitFrame && result.musicalMap == .initial)
            try result.validateMediaShape()
        }
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
    }

    @Test(arguments: [StoppedPolicy.wait, .immediate, .startTransport])
    func finding1250MissingContextIsNotStopped(policy: StoppedPolicy) throws {
        var fixture = try SchedulerFixture(capacity: 3)
        try fixture.prepareMusical(0)
        var stamps: [TriggerStamp] = []
        for id: StaticString in ["trg.1250.nil", "trg.1250.stale", "trg.1250.a2"] {
            var stamp = fixture.musicalStamp(id, .musical(atTicks: 0), originHost: 0, arrival: 100)
            stamp.stoppedPolicy = policy
            stamps.append(stamp)
        }
        let handles = try stamps.map { try fixture.submitMusical($0) }
        try fixture.observeMusical(.running(false), 100, ticks: 64)
        let invalid = { (handle: TriggerHandle) in
            TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .invalidTiming)
        }
        // Missing or stale witnesses fail closed: never wait, start the transport or fire.
        #expect(try fixture.commitMusical(handles[0], at: 100, sequence: nil) == .completed)
        #expect(try fixture.drainOne(handles[0]) == invalid(handles[0]))
        #expect(try fixture.commitMusical(handles[1], at: 100, sequence: 0) == .completed)
        #expect(try fixture.drainOne(handles[1]) == invalid(handles[1]))
        // A2's forwarding signature names no sequence, so it can never discard a .startTransport.
        try fixture.commit(handles[2], at: 100)
        #expect(try fixture.drainOne(handles[2]) == invalid(handles[2]))
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.pendingCount == 0)
    }

    @Test(arguments: [false, true])
    func musicalReadinessPrecedesProjection(initiallyReady: Bool) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        if !initiallyReady { fixture.readiness = ActionReadiness() }
        let handle = try fixture.submitMusical(fixture.musicalStamp("trg.ready", .musical(atTicks: 960),
                                                                    originHost: 0, arrival: 100))
        // Captured-unready work is never pinned; captured-ready work is.
        #expect(fixture.scheduler.pendingMusic(handle) == (initiallyReady
            ? .pinned(MusicalOccurrence(pass: 0, ticks: 960)) : nil))
        if initiallyReady { try fixture.readiness.transition(SchedulerFixture.action, to: .invalidated) }
        try fixture.prepare()
        #expect(try fixture.commitMusical(handle, at: 100) == .completed)
        #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                               reason: .notReady))
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
    }

    @Test func pendingMusicalTargetsUseTheCurrentMapWithoutCancellation() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        let handle = try fixture.submitMusical(fixture.musicalStamp("trg.map", .musical(atTicks: 960),
                                                                    originHost: 0, arrival: 100))
        let revision = try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
        try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 1_000_000)), 0)
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 960)))
        try fixture.commitMusical(handle, at: 100)
        // Doubling the quarter length doubles the projected frame (1_500 -> 3_000) under the new revision.
        #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .fired,
                                                               assignedFrame: 3_000, frame: 3_000,
                                                               musicalMap: revision))
    }

    @Test func pinlessOutsideLoopDiagnosisNamesTheCurrentMap() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
        let handle = try fixture.submitMusical(fixture.musicalStamp("trg.outside", .musical(atTicks: 3_000),
                                                                    originHost: 0, arrival: 100))
        try fixture.commitMusical(handle, at: 100)
        #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                               reason: .outsideLoop, musicalMap: .initial))
    }

    /// Commit-time projection history failures are unreachable once observations refresh every pin;
    /// the reachable non-consuming commit refusals must still keep the pin, pending entry and horizon.
    /// Both refusals below come from the staged horizon advance, before any musical resolution.
    @Test func refusedMusicalCommitPreservesPendingPinAndHorizon() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        let handle = try fixture.submitMusical(fixture.musicalStamp("trg.keep", .musical(atTicks: 960),
                                                                    originHost: 0, arrival: 100))
        let before = try fixture.admissionState()
        #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commitMusical(handle, at: 99) }
        #expect(throws: ClockMapError.invalidRate(96_000)) {
            try fixture.scheduler.commit(handle, at: fixture.sample(100), nominalRate: 96_000,
                                         context: fixture.musicalContext(0))
        }
        #expect(try fixture.admissionState() == before && before.music?.pinCount == 1)
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 960)))
        #expect(fixture.scheduler.drain().isEmpty)
        try fixture.commitMusical(handle, at: 100)
        #expect(try fixture.drainOne(handle).frame == 1_500)
    }
}

extension ControlContractTests.MusicalScheduling {
    @Test(arguments: [false, true])
    func submitRefusesStaleMusicalContextWithoutConsumingAdmission(unobservedMap: Bool) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        let stamp = fixture.musicalStamp("trg.stale-music", .musical(atTicks: 960), originHost: 0, arrival: 10)
        var witness: UInt64 = 1
        if unobservedMap {
            // The stamp does not depend on the map key, so only the context check can refuse it.
            try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
            witness = 0
        }
        let before = try fixture.admissionState()
        #expect(throws: TriggerSchedulerError.staleMusicalContext) {
            try fixture.scheduler.submit(stamp, session: fixture.scheduler.currentToken,
                                         context: fixture.musicalContext(witness))
        }
        #expect(try fixture.admissionState() == before && fixture.scheduler.drain().isEmpty)
    }

    @Test(arguments: [false, true])
    func bypassedMusicalRequestsAreAdmittedPinless(stale: Bool) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        // An uncovered origin would refuse a ready request; neither bypass resolves music.
        let stamp = fixture.musicalStamp("trg.bypass", .grid(ticks: 960), originHost: 10_000_000, arrival: 10)
        if stale {
            try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange)
        } else {
            fixture.readiness = ActionReadiness()
        }
        let handle = try fixture.submitMusical(stamp)
        #expect(fixture.scheduler.pendingMusic(handle) == nil)
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.reservedOutcomeCount == 1)
        if stale {
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .rejectedStale,
                                                                   stale: .generation(SchedulerFixture.context)))
        } else {
            #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.drain().isEmpty)
        }
    }
}

/// Late nextBoundary fallback through the timeline (M2, M8).
extension ControlContractTests.MusicalScheduling {
    @Test func retroactiveWindowAndTriggerGridOverrideAreApplied() throws {
        var fixture = try SchedulerFixture(capacity: 4)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_000))
        try fixture.observeMusical(.primary, 100)
        // Origin ticks 64: a 5 ms window reaches back to the grid line at frame 0.
        var retro = fixture.musicalStamp("trg.retro", .grid(ticks: 960), originHost: 50_000,
                                         policy: .joinInProgress(maxLatenessMs: 10), arrival: 100)
        retro.retroactiveMs = 5
        let joined = try fixture.resolveMusical(retro, at: 200)
        #expect(joined == TriggerOutcome(trigger: joined.trigger, result: .joined, assignedFrame: 0, frame: 200,
                                         startOffsetFrames: 200, musicalMap: .initial))
        // The trigger's 960 grid overrides the policy's 15_360: 960 is still inside the 0...1_000 loop.
        let resolved = try fixture.resolveMusical(fixture.boundaryStamp("trg.override", .grid(ticks: 960),
                                                                        grid: 15_360), at: 1_000)
        #expect(resolved == TriggerOutcome(trigger: resolved.trigger, result: .fired, assignedFrame: 1_500,
                                           frame: 1_500, musicalMap: .initial))
    }

    @Test func nextBoundaryRequiresTransportAndNamesTheMapRevisionInsideTheLoop() throws {
        var fixture = try SchedulerFixture(capacity: 2)
        try fixture.prepareMusical(0)
        let before = try fixture.admissionState()
        let bare = fixture.stamp("trg.bare", .asap, policy: .nextBoundary(gridTicks: 15_360))
        #expect(throws: TriggerValidationError.nextBoundaryWithoutTransport) { try fixture.submitMusical(bare) }
        #expect(try fixture.admissionState() == before)
        let fired = try fixture.resolveMusical(fixture.boundaryStamp("trg.nb", .sample(atFrame: 1_000),
                                                                     grid: 15_360), at: 30_000)
        #expect(fired == TriggerOutcome(trigger: fired.trigger, result: .fired, assignedFrame: 48_000,
                                        frame: 48_000, musicalMap: .initial))
        try fired.validateMediaShape()
        // Grid 960 at frame 30_001: the old map's next line is frame 31_500, the edited (half-speed) map's
        // is 33_000, so the frame itself proves the new map is used, under the new revision.
        let revision = try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
        try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 1_000_000)), 30_000)
        let edited = try fixture.resolveMusical(fixture.boundaryStamp("trg.edit", .sample(atFrame: 1_000),
                                                                      grid: 960), at: 30_001)
        #expect(edited == TriggerOutcome(trigger: edited.trigger, result: .fired, assignedFrame: 33_000,
                                         frame: 33_000, musicalMap: revision))
        var looped = try SchedulerFixture(capacity: 2)
        try looped.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 23_040))
        let wrapped = try looped.resolveMusical(looped.boundaryStamp("trg.loop", .sample(atFrame: 1_000),
                                                                     grid: 15_360), at: 30_000)
        #expect(wrapped == TriggerOutcome(trigger: wrapped.trigger, result: .fired, assignedFrame: 36_000,
                                          frame: 36_000, musicalMap: .initial))
        try wrapped.validateMediaShape()
        let located = try looped.submitMusical(looped.boundaryStamp("trg.loc", .asap, grid: 15_360))
        try looped.ledger.bump(SchedulerFixture.transport, reason: .locate(ticks: 0))
        try looped.commitMusical(located, at: 30_001)
        #expect(try looped.drainOne(located) == TriggerOutcome(trigger: located.trigger, result: .cancelled,
                                                               stale: .generation(SchedulerFixture.transport)))
    }
}
