import Testing
@testable import FluxKlang

/// One M12 resume-provenance candidate offered as the `running(true)` observation of a stopped timeline.
/// `accepted` is the zero-baseline result; with an `Int64.min` baseline every frame near 6_000 is
/// 2^63 frames from its prediction, so only refusals that fire before the drift check keep their kind.
struct ResumeCandidate: Sendable, CustomTestStringConvertible {
    enum Variant: Sendable { case plain, generation, transport, pass, ticks, untimed, foreignClock }

    let frame: Int64
    let host: UInt64
    var variant: Variant = .plain
    /// `nil` means the candidate is tolerated and the resume is accepted.
    var refusal: MusicalTimingError?

    var testDescription: String { "\(variant) \(frame)@\(host)" }

    /// Refusals decided by identity/ledger checks precede the drift check and survive any baseline.
    func expected(baseline: Int64) -> MusicalTimingError? {
        if baseline == 0 || [.generation, .transport, .foreignClock].contains(variant) { return refusal }
        return .invalidContext
    }

    static let invalid: [Self] = [
        Self(frame: 6_000, host: 3_000_000, variant: .generation, refusal: .invalidContext),
        Self(frame: 6_000, host: 3_000_000, variant: .transport, refusal: .invalidContext),
        Self(frame: 6_000, host: 3_000_000, variant: .pass, refusal: .invalidTransition),
        Self(frame: 6_000, host: 3_000_000, variant: .ticks, refusal: .invalidTransition),
        Self(frame: 0, host: 0, refusal: .timeRegressed),
        Self(frame: 0, host: 3_000_000, refusal: .invalidContext),
        Self(frame: 5_945, host: 3_000_000, refusal: .invalidContext),
        Self(frame: 6_055, host: 3_000_000, refusal: .invalidContext),
        Self(frame: 5_946, host: 3_000_250, refusal: .invalidContext),
        Self(frame: 6_055, host: 3_000_250, refusal: .invalidContext),
        Self(frame: 6_000, host: 3_000_000, variant: .untimed, refusal: .invalidContext),
        Self(frame: 6_000, host: 3_000_000, variant: .foreignClock, refusal: .invalidContext)
    ]

    /// At 6_000 predicted frames the exact budget is 54; half-frame predictions keep their fraction.
    static let tolerated: [Self] = [
        Self(frame: 6_000, host: 3_000_000), Self(frame: 5_946, host: 3_000_000),
        Self(frame: 6_054, host: 3_000_000), Self(frame: 6_001, host: 3_000_250),
        Self(frame: 5_947, host: 3_000_250), Self(frame: 6_054, host: 3_000_250)
    ]
}

private extension SchedulerFixture {
    /// M12's stopped origin: stopped at ticks 0 on `baseline`, grid 1_440 requested at baseline + 5_000.
    static func stoppedOrigin(baseline: Int64) throws -> (SchedulerFixture, TriggerHandle) {
        var fixture = try SchedulerFixture(capacity: 1, frame: baseline, host: 0)
        try fixture.scheduler.prepareMusical(SchedulerMusicalSetup(
            anchor: fixture.anchor(baseline, host: 0, ticks: 0), map: fixture.map(),
            loop: LoopRange(startTicks: 0, endTicks: 1_920), running: false, historyLimit: 4), ledger: fixture.ledger)
        try fixture.observeMusical(.primary, at: fixture.anchor(baseline + 5_000, host: 2_500_000))
        let handle = try fixture.submitMusical(fixture.musicalStamp(
            "trg.resume", .grid(ticks: 1_440), originHost: 2_500_000, policy: .fireLate(maxLatenessMs: 100),
            arrival: baseline + 5_000))
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
        return (fixture, handle)
    }

    func resumeAnchor(_ candidate: ResumeCandidate) throws -> ClockAnchor {
        let valid = try anchor(candidate.frame, host: candidate.host, ticks: 0)
        let musical = try #require(valid.musical)
        switch candidate.variant {
        case .plain: return valid
        case .ticks: return try anchor(candidate.frame, host: candidate.host, ticks: 960)
        case .pass: return try anchor(candidate.frame, host: candidate.host, ticks: 0, pass: 1)
        case .untimed: return try anchor(candidate.frame, host: candidate.host)
        case .generation:
            return try ClockAnchor(sample: sample(candidate.frame, generation: Generation(2)), host: valid.host,
                                   musical: musical)
        case .transport:
            return ClockAnchor(sample: valid.sample, host: valid.host, musical: MusicalStamp(
                transport: try Generation(2), musicalMap: musical.musicalMap, ticks: 0, loopIteration: 0))
        case .foreignClock:
            return ClockAnchor(sample: SampleStamp(clock: ClockID(validated: "smp.other"), generation: .initial,
                                                   frame: candidate.frame), host: valid.host, musical: musical)
        }
    }
}

extension ControlContractTests {
    struct SchedulerResumeAcceptance {
        /// M12 refusals: each invalid provenance is refused atomically; the stopped pin keeps waiting.
        @Test(arguments: [Int64(0), .min], ResumeCandidate.invalid)
        func stoppedOriginRefusesInvalidResumeProvenance(baseline: Int64, candidate: ResumeCandidate) throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: baseline)
            let before = try fixture.admissionState()
            let resume = try fixture.resumeAnchor(candidate)
            #expect(throws: try #require(candidate.expected(baseline: baseline))) {
                try fixture.observeMusical(.running(true), at: resume)
            }
            #expect(try fixture.admissionState() == before && fixture.scheduler.drain().isEmpty)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
        }

        /// M12 tolerated provenance: the resume anchors pass 0 at the candidate frame; delivered just after
        /// the next wrap it fires late with the resume frame as the assigned identity.
        /// Phase adaptation: the horizon is the candidate's own wrap + 1 (9_001 for the exact 6_000 resume),
        /// because the wrap observation must be at the resume frame + 3_000.
        @Test(arguments: ResumeCandidate.tolerated)
        func stoppedOriginAcceptsToleratedResumeProvenance(candidate: ResumeCandidate) throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: 0)
            #expect(try fixture.commitMusical(handle, at: 5_000) == .waitingForTransport)
            try fixture.observeMusical(.running(true), at: fixture.resumeAnchor(candidate))
            let wrap = candidate.frame + 3_000
            try fixture.observeMusical(.wrap, at: fixture.anchor(wrap, host: candidate.host + 1_500_000, ticks: 0,
                                                                 pass: 1))
            #expect(try fixture.commitMusical(handle, at: wrap + 1) == .completed)
            let outcome = try fixture.drainOne(handle)
            #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .firedLate,
                                              assignedFrame: candidate.frame, frame: wrap + 1, musicalMap: .initial))
            try outcome.validateMediaShape()
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.pendingCount == 0)
            #expect(try fixture.snapshot().horizon?.frame == wrap + 1 && fixture.scheduler.reservedOutcomeCount == 0)
        }

        /// M12 tolerated candidates with an `Int64.min` baseline are 2^63 frames off: refused, still waiting.
        @Test(arguments: ResumeCandidate.tolerated)
        func minimumBaselineRefusesEveryNearSixThousandResume(candidate: ResumeCandidate) throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: .min)
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.invalidContext) {
                try fixture.observeMusical(.running(true), at: fixture.resumeAnchor(candidate))
            }
            #expect(try fixture.admissionState() == before)
            #expect(try fixture.commitMusical(handle, at: .min + 9_001) == .waitingForTransport)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
        }

        /// M12 `nil` provenance: without a resume the wrap cannot be observed and the commit keeps waiting.
        @Test func stoppedOriginWithoutResumeKeepsWaiting() throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: 0)
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observeMusical(.wrap, at: fixture.anchor(9_000, ticks: 0, pass: 1))
            }
            #expect(try fixture.admissionState() == before)
            #expect(try fixture.commitMusical(handle, at: 9_001) == .waitingForTransport)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
            #expect(fixture.scheduler.drain().isEmpty && fixture.scheduler.musicalSummary?.pinCount == 1)
        }

        /// M12 resume after the delivery point (10_000): the observation is valid provenance now, so the
        /// original horizon 9_001 is a regressing commit that consumes nothing.
        @Test func resumeAfterTheDeliveryPointRefusesTheEarlierHorizon() throws {
            var (fixture, handle) = try SchedulerFixture.stoppedOrigin(baseline: 0)
            try fixture.observeMusical(.running(true), at: fixture.anchor(10_000, host: 5_000_000, ticks: 0))
            let before = try fixture.admissionState()
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commitMusical(handle, at: 9_001) }
            #expect(try fixture.admissionState() == before && fixture.scheduler.drain().isEmpty)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 0)))
        }

        /// T11: running submission, stop before ticks 1_440, resume at 6_000 (ticks 960) so 1_440 is 6_750;
        /// after the wrap at 7_500 the pass-0 resume anchor still projects it, even with history 1.
        @Test(arguments: [4, 1])
        func finding1285RunningSubmissionThenStopResumeWrapKeepsResume(history: Int) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920), history: history)
            let handle = try fixture.submitMusical(fixture.musicalStamp(
                "trg.1285.resume", .musical(atTicks: 1_440), originHost: 0, policy: .fireLate(maxLatenessMs: 100)))
            try fixture.observeMusical(.running(false), 1_500, ticks: 960)
            #expect(try fixture.commitMusical(handle, at: 1_500) == .waitingForTransport)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 1_440)))
            try fixture.observeMusical(.running(true), 6_000, ticks: 960)
            try fixture.observeMusical(.wrap, 7_500, ticks: 0, pass: 1)
            #expect(fixture.scheduler.musicalSummary?.historyCount == min(history, 4))
            #expect(try fixture.commitMusical(handle, at: 7_501) == .completed)
            #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .firedLate,
                                                                   assignedFrame: 6_750, frame: 7_501,
                                                                   musicalMap: .initial))
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.pendingCount == 0)
            #expect(fixture.scheduler.pendingMusic(handle) == nil && fixture.scheduler.reservedOutcomeCount == 0)
            #expect(try fixture.snapshot().horizon?.frame == 7_501)
        }

        /// T12 (disputed 750 retired): ticks 480 was already passed when the transport stopped at 1_500;
        /// `.wait` holds it, and after a same-pass resume at 6_000 (ticks 960) its identity projects
        /// through the resume anchor to 5_250, dispatched late at the validated horizon 6_001.
        @Test func samePassResumeUses5250AndDispatchesAtValidatedHorizon() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            let handle = try fixture.submitMusical(fixture.musicalStamp(
                "trg.1285.past", .musical(atTicks: 480), originHost: 0, policy: .fireLate(maxLatenessMs: 100)))
            try fixture.observeMusical(.running(false), 1_500, ticks: 960)
            #expect(try fixture.commitMusical(handle, at: 1_500) == .waitingForTransport)
            try fixture.observeMusical(.running(true), 6_000, ticks: 960)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 480)))
            #expect(try fixture.commitMusical(handle, at: 6_001) == .completed)
            let outcome = try fixture.drainOne(handle)
            #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .firedLate, assignedFrame: 5_250,
                                              frame: 6_001, musicalMap: .initial))
            #expect(outcome.assignedFrame != 750)
            #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.pendingCount == 0)
            #expect(try fixture.snapshot().horizon?.frame == 6_001 && fixture.scheduler.reservedOutcomeCount == 0)
        }
    }
}
