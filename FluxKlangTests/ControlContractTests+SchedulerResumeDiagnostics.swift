import Testing
@testable import FluxKlang

/// Pinless `outsideLoop` fixture: loop 0..1_920 (3_000 frames), ticks 3_000 requested at frame 1_500.
private extension SchedulerFixture {
    static func pinlessOutsideLoop(stopped: StoppedPolicy = .wait) throws -> (SchedulerFixture, TriggerHandle) {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
        try fixture.observeMusical(.primary, 1_500)
        var stamp = fixture.musicalStamp("trg.outside", .musical(atTicks: 3_000), originHost: 375_000,
                                         arrival: 1_500)
        stamp.stoppedPolicy = stopped
        let handle = try fixture.submitMusical(stamp)
        #expect(fixture.scheduler.pendingMusic(handle) == .outsideLoop)
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
        return (fixture, handle)
    }

    /// The commit retired the request: no pin, pending entry or reserved slot remains.
    func expectRetired(_ handle: TriggerHandle) {
        #expect(scheduler.musicalSummary?.pinCount == 0 && scheduler.pendingCount == 0)
        #expect(scheduler.pendingMusic(handle) == nil && scheduler.reservedOutcomeCount == 0)
    }
}

extension ControlContractTests {
    /// C3: the M12 refused-resume diagnostic and the precedence of the pinless `outsideLoop` diagnosis.
    /// Diagnostics are not V1-shaped, so they are compared by exact equality only.
    struct SchedulerResumeDiagnostics {
        /// Every M12 refusal: both baselines for invalid provenance, and `Int64.min` for the tolerated set.
        static let refusedResumes: [(Int64, ResumeCandidate)] =
            [Int64(0), .min].flatMap { baseline in ResumeCandidate.invalid.map { (baseline, $0) } }
            + ResumeCandidate.tolerated.map { (Int64.min, $0) }

        /// The refused candidate used by the precedence rows: 55 frames early, past the 54-frame budget.
        static let refused = ResumeCandidate(frame: 5_945, host: 3_000_000, refusal: .invalidContext)

        /// M12 disposition. Pinned here: a refused resume publishes nothing and does NOT advance the retained
        /// sequence, so a commit naming the refused attempt's number (retained + 1) is a stale witness and
        /// ends the waiting pin with strict invalidTiming instead of applying the stopped policy.
        @Test(arguments: refusedResumes)
        func refusedResumeIsDiagnosedAtTheNextCommit(baseline: Int64, candidate: ResumeCandidate) throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: baseline)
            #expect(try fixture.commitMusical(handle, at: baseline + 5_000) == .waitingForTransport)
            let retained = try #require(fixture.scheduler.musicalSummary?.observationSequence)
            let resume = try fixture.resumeAnchor(candidate)
            let before = try fixture.admissionState()
            #expect(throws: try #require(candidate.expected(baseline: baseline))) {
                try fixture.observeMusical(.running(true), at: resume)
            }
            #expect(try fixture.admissionState() == before)
            #expect(fixture.scheduler.musicalSummary?.observationSequence == retained)
            #expect(try fixture.commitMusical(handle, at: baseline + 9_001, sequence: retained + 1) == .completed)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                                   reason: .invalidTiming))
            fixture.expectRetired(handle)
            #expect(try fixture.snapshot().horizon?.frame == baseline + 9_001)
        }

        /// The witness check precedes the stopped check: no stopped policy can fire or start the transport
        /// for a refused attempt, while a twin naming the retained sequence gets its stopped policy.
        @Test(arguments: [StoppedPolicy.wait, .immediate, .startTransport])
        func refusedResumeDiagnosisOverridesStoppedPolicies(policy: StoppedPolicy) throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: 0, stopped: policy)
            var (twin, twinHandle) = try SchedulerFixture.stoppedOrigin(baseline: 0, stopped: policy)
            let retained = try #require(fixture.scheduler.musicalSummary?.observationSequence)
            #expect(throws: MusicalTimingError.invalidContext) {
                try fixture.observeMusical(.running(true), at: fixture.resumeAnchor(Self.refused))
            }
            #expect(throws: MusicalTimingError.invalidContext) {
                try twin.observeMusical(.running(true), at: twin.resumeAnchor(Self.refused))
            }
            #expect(try fixture.commitMusical(handle, at: 5_000, sequence: retained + 1) == .completed)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                                   reason: .invalidTiming))
            fixture.expectRetired(handle)

            let fired = TriggerOutcome(trigger: twinHandle.trigger, result: .fired, assignedFrame: 5_000, frame: 5_000)
            let disposition = try twin.commitMusical(twinHandle, at: 5_000, sequence: retained)
            switch policy {
            case .wait:
                #expect(disposition == .waitingForTransport && twin.scheduler.drain().isEmpty)
                try twin.endWaiting(twinHandle)
            case .immediate:
                #expect(disposition == .completed)
                #expect(try twin.drainOne(twinHandle) == fired)
            case .startTransport:
                #expect(disposition == .startTransport)
                #expect(try twin.drainOne(twinHandle) == fired)
            }
        }

        /// Stale requirements and readiness still win over the witness diagnosis: a locate cancels the
        /// waiting request naming `transport`, and invalidated readiness drops it as notReady.
        @Test(arguments: [true, false])
        func refusedResumeDiagnosisYieldsToCancellationAndReadiness(cancelled: Bool) throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: 0)
            let retained = try #require(fixture.scheduler.musicalSummary?.observationSequence)
            #expect(throws: MusicalTimingError.invalidContext) {
                try fixture.observeMusical(.running(true), at: fixture.resumeAnchor(Self.refused))
            }
            if cancelled {
                try fixture.ledger.bump(SchedulerFixture.transport, reason: .locate(ticks: 0))
            } else {
                try fixture.readiness.transition(SchedulerFixture.action, to: .invalidated)
            }
            #expect(try fixture.commitMusical(handle, at: 9_001, sequence: retained + 1) == .completed)
            let expected = cancelled
                ? TriggerOutcome(trigger: handle.trigger, result: .cancelled,
                                 stale: .generation(SchedulerFixture.transport))
                : TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .notReady)
            #expect(try fixture.drainOne(handle) == expected)
            fixture.expectRetired(handle)
        }

        /// The witness is the latest ATTEMPTED sequence: a refused attempt does not advance the retained
        /// sequence, nothing newer is current, and the producer's retry reuses the refused number.
        @Test func retriedResumeReusesTheRefusedSequence() throws {
            // Capacity 2 leaves a free slot, so a second submit reaches the musical freshness check.
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: 0, capacity: 2)
            #expect(try fixture.commitMusical(handle, at: 5_000) == .waitingForTransport)
            let retained = try #require(fixture.scheduler.musicalSummary?.observationSequence)
            let attempt = retained + 1
            let early = ResumeCandidate(frame: 6_055, host: 3_000_000, refusal: .invalidContext)
            #expect(throws: MusicalTimingError.invalidContext) {
                try fixture.observeMusical(.running(true), at: fixture.resumeAnchor(early), sequence: attempt)
            }
            let before = try fixture.admissionState()
            // Neither the refused number nor a later one is current: the query and a real submit both refuse
            // it, and the submit consumes nothing.
            let retry = fixture.musicalStamp("trg.retry", .grid(ticks: 1_440), originHost: 2_500_000,
                                             arrival: 5_000)
            for named in [attempt, retained + 3] {
                #expect(throws: TriggerSchedulerError.staleMusicalContext) {
                    try fixture.scheduler.requireMusicalContext(fixture.musicalContext(named))
                }
                #expect(throws: TriggerSchedulerError.staleMusicalContext) {
                    try fixture.scheduler.submit(retry, session: fixture.scheduler.currentToken,
                                                 context: fixture.musicalContext(named))
                }
                #expect(try fixture.admissionState() == before)
            }
            try fixture.observeMusical(.running(true), at: fixture.anchor(6_000, host: 3_000_000, ticks: 0),
                                       sequence: attempt)
            #expect(fixture.scheduler.musicalSummary?.observationSequence == attempt)
            try fixture.observeMusical(.wrap, at: fixture.anchor(9_000, host: 4_500_000, ticks: 0, pass: 1))
            #expect(try fixture.commitMusical(handle, at: 9_001) == .completed)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .firedLate,
                                                                   assignedFrame: 6_000, frame: 9_001,
                                                                   musicalMap: .initial))
            fixture.expectRetired(handle)
        }

        /// A missing or stale witness wins over the pinless diagnosis: strict invalidTiming naming no map.
        @Test(arguments: [nil, UInt64(2)])
        func pinlessOutsideLoopYieldsToAMissingOrStaleWitness(sequence: UInt64?) throws {
            var (fixture, handle) = try SchedulerFixture.pinlessOutsideLoop()
            #expect(fixture.scheduler.musicalSummary?.observationSequence == 1)
            #expect(try fixture.commitMusical(handle, at: 1_500, sequence: sequence) == .completed)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                                   reason: .invalidTiming))
            fixture.expectRetired(handle)
        }

        /// A valid stopped context never applies a stopped policy to a pinless request: it neither waits
        /// nor starts the transport, and names the current map.
        @Test(arguments: [StoppedPolicy.wait, .immediate, .startTransport])
        func pinlessOutsideLoopPrecedesStoppedPolicies(policy: StoppedPolicy) throws {
            var (fixture, handle) = try SchedulerFixture.pinlessOutsideLoop(stopped: policy)
            try fixture.observeMusical(.running(false), 1_500, ticks: 960)
            #expect(fixture.scheduler.musicalSummary?.isRunning == false)
            #expect(try fixture.commitMusical(handle, at: 1_500) == .completed)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                                   reason: .outsideLoop, musicalMap: .initial))
            fixture.expectRetired(handle)
        }

        /// The diagnosis is fixed at admission (a later wider loop does not re-admit it), while the map is
        /// named at resolution (the tempo edit's revision 2, not the admission-time `.initial`).
        @Test func pinlessOutsideLoopIsFrozenAtAdmissionAndNamesTheResolutionMap() throws {
            var (fixture, handle) = try SchedulerFixture.pinlessOutsideLoop()
            try fixture.observeMusical(.loop(LoopRange(startTicks: 0, endTicks: 3_840)), 1_600)
            try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
            try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 1_000_000)), 1_700)
            #expect(fixture.scheduler.pendingMusic(handle) == .outsideLoop)
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
            #expect(try fixture.commitMusical(handle, at: 1_700) == .completed)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                                   reason: .outsideLoop,
                                                                   musicalMap: try Generation(2)))
            fixture.expectRetired(handle)
        }
    }
}
