import Testing
@testable import FluxKlang

struct SchedulerAdmissionState: Equatable {
    let clock: SchedulerClock.Snapshot
    let music: SchedulerMusicalSummary?
    let pending: Int
    let reserved: Int
}

/// Test-local musical composition helpers over the accepted sample-scheduler fixture,
/// shared by the scheduler musical suites.
extension SchedulerFixture {
    static let mapKey = GenerationKey(.musicalMap, musical)

    /// Timebase 125/3 at 48 kHz: one frame is exactly 500 host ticks unless a drifted host is given.
    func anchor(_ frame: Int64, host: UInt64? = nil, ticks: Int64? = nil, pass: UInt32 = 0) throws -> ClockAnchor {
        let musical = try ticks.map {
            MusicalStamp(transport: try #require(ledger.generation(Self.transport)),
                         musicalMap: try #require(ledger.generation(Self.mapKey)), ticks: $0, loopIteration: pass)
        }
        return try ClockAnchor(sample: sample(frame), host: .init(ticks: host ?? UInt64(frame) * 500),
                               musical: musical)
    }

    func map(microsPerQuarter: Int64 = 500_000) throws -> MusicalMap {
        try MusicalMap(clock: Self.musical, revision: #require(ledger.generation(Self.mapKey)),
                       segments: [TempoSegment(atTicks: 0, microsPerQuarter: microsPerQuarter)])
    }

    func musicalContext(_ sequence: UInt64?) -> TriggerSchedulerContext {
        TriggerSchedulerContext(ledger: ledger, readiness: readiness, musicalSequence: sequence)
    }

    mutating func prepareMusical(_ frame: Int64, ticks: Int64 = 0, loop: LoopRange? = nil,
                                 history: Int = 4, running: Bool = true) throws {
        let setup = SchedulerMusicalSetup(anchor: try anchor(frame, ticks: ticks), map: try map(), loop: loop,
                                          running: running, historyLimit: history)
        try scheduler.prepareMusical(setup, ledger: ledger)
    }

    mutating func observeMusical(_ event: MusicalObservation, _ frame: Int64, ticks: Int64? = nil,
                                 pass: UInt32 = 0, sequence: UInt64? = nil) throws {
        try observeMusical(event, at: anchor(frame, ticks: ticks, pass: pass), sequence: sequence)
    }

    mutating func observeMusical(_ event: MusicalObservation, at anchor: ClockAnchor,
                                 sequence: UInt64? = nil) throws {
        let next = sequence ?? (scheduler.musicalSummary?.observationSequence ?? 0) + 1
        try scheduler.observeMusical(event, at: anchor, sequence: next, ledger: ledger)
    }

    /// A ready musical request whose origin is an explicit host instant.
    func musicalStamp(_ id: StaticString, _ target: TriggerTarget, originHost: UInt64,
                      policy: LatePolicy = .drop, arrival: Int64 = 0) -> TriggerStamp {
        let base = stamp(id, target, policy: policy, arrival: arrival)
        return TriggerStamp(id: base.id, action: base.action, originHost: .init(ticks: originHost),
                            horizonFrame: base.horizonFrame, requires: base.requires, target: base.target,
                            latePolicy: base.latePolicy)
    }

    /// Commits with the producer's latest retained sequence unless another witness is named.
    @discardableResult
    mutating func commitMusical(_ handle: TriggerHandle, at frame: Int64) throws -> SchedulerCommitDisposition {
        try commitMusical(handle, at: frame, sequence: scheduler.musicalSummary?.observationSequence)
    }

    @discardableResult
    mutating func commitMusical(_ handle: TriggerHandle, at frame: Int64,
                                sequence: UInt64?) throws -> SchedulerCommitDisposition {
        try scheduler.commit(handle, at: sample(frame), nominalRate: ledger.nominalRate,
                             context: musicalContext(sequence))
    }

    /// Every scheduler-owned value an atomic refusal must leave unchanged.
    func admissionState() throws -> SchedulerAdmissionState {
        SchedulerAdmissionState(clock: try snapshot(), music: scheduler.musicalSummary,
                                pending: scheduler.pendingCount, reserved: scheduler.reservedOutcomeCount)
    }

    /// Names the producer's latest retained sequence, as a current owner would.
    mutating func submitMusical(_ stamp: TriggerStamp) throws -> TriggerHandle {
        try scheduler.submit(stamp, session: scheduler.currentToken,
                             context: musicalContext(scheduler.musicalSummary?.observationSequence))
    }
}

extension ControlContractTests {
    struct SchedulerMusicalLifecycle {
        @Test func musicalPreparationUsesBaselineNotLatestPhysicalMapping() throws {
            var fixture = try SchedulerFixture(capacity: 2)
            #expect(fixture.scheduler.musicalSummary == nil)
            #expect(throws: TriggerSchedulerError.musicalContextRequired) {
                try fixture.scheduler.requireMusicalContext(fixture.musicalContext(0))
            }
            try fixture.observe(3_000, host: 1_500_000)
            let physical = try fixture.snapshot()
            let baseline = try #require(physical.baseline)
            #expect(baseline.anchor.sample.frame == 0 && physical.latestAnchor?.sample.frame == 3_000)
            try fixture.prepareMusical(3_000)
            let prepared = try #require(fixture.scheduler.musicalSummary)
            // The genuine drift baseline, never requireReady's rolling latest-anchor mapping.
            #expect(prepared.sample == baseline && prepared.sample.anchor != physical.latestAnchor)
            #expect(prepared.firstAnchor == (try fixture.anchor(3_000, ticks: 0)))
            #expect(prepared.latestPrimary == prepared.firstAnchor && prepared.observationSequence == 0)
            #expect(prepared.historyLimit == 4 && prepared.pinLimit == 2 && prepared.pinCount == 0)
            #expect(try fixture.snapshot() == physical)
            #expect(try fixture.scheduler.requireMusicalContext(fixture.musicalContext(0)) == prepared)
            // A second preparation would conceal missing history; it is refused atomically.
            #expect(throws: TriggerSchedulerError.musicalAlreadyPrepared) { try fixture.prepareMusical(4_500) }
            #expect(try fixture.scheduler.musicalSummary == prepared && fixture.snapshot() == physical)
            // A transport locate reset delegates to the timeline with the same retained baseline.
            try fixture.ledger.bump(SchedulerFixture.transport, reason: .locate(ticks: 960))
            let reset = SchedulerMusicalReset(anchor: try fixture.anchor(4_500, ticks: 960), map: try fixture.map(),
                                              sequence: 1)
            try fixture.scheduler.resetMusical(reset, ledger: fixture.ledger)
            let relocated = try #require(fixture.scheduler.musicalSummary)
            #expect(relocated.sample == baseline && relocated.firstAnchor == reset.anchor)
            #expect(relocated.observationSequence == 1 && relocated.historyCount == 1)
            #expect(try fixture.snapshot().baseline == baseline)
            #expect(try fixture.snapshot().latestAnchor == ClockAnchor(sample: fixture.sample(4_500),
                                                                       host: .init(ticks: 2_250_000)))
        }

        @Test func failedMusicalObservationPreservesClockTimelineAndSequence() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let prepared = try #require(fixture.scheduler.musicalSummary)
            let before = try fixture.snapshot()
            // The clock would accept this anchor; the timeline refuses the sequence gap.
            #expect(throws: MusicalTimingError.observationGap) {
                try fixture.observeMusical(.primary, 1_500, sequence: 2)
            }
            #expect(try fixture.scheduler.musicalSummary == prepared && fixture.snapshot() == before)
            // The timeline would accept this anchor; the clock refuses an older physical observation.
            try fixture.observe(3_000, host: 1_500_000)
            let observed = try fixture.snapshot()
            #expect(throws: SchedulerClockError.invalidAnchor) { try fixture.observeMusical(.primary, 1_500) }
            #expect(try fixture.scheduler.musicalSummary == prepared && fixture.snapshot() == observed)
            // Neither side published: the same sequence remains the next valid one.
            try fixture.observeMusical(.musical, 3_000, ticks: 1_920)
            let accepted = try #require(fixture.scheduler.musicalSummary)
            #expect(accepted.observationSequence == 1 && accepted.historyCount == 2)
            #expect(accepted.latestPrimary == (try fixture.anchor(3_000, ticks: 1_920)))
            #expect(try fixture.snapshot().latestAnchor == observed.latestAnchor)
        }

        @Test func newSequenceWitnessCannotUseRejectedObservation() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let prepared = try #require(fixture.scheduler.musicalSummary)
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observeMusical(.musical, 750, ticks: 999)
            }
            #expect(fixture.scheduler.musicalSummary == prepared)
            // A request naming the producer's newer sequence cannot fall back to the old timeline.
            #expect(throws: TriggerSchedulerError.staleMusicalContext) {
                try fixture.scheduler.requireMusicalContext(fixture.musicalContext(1))
            }
            #expect(throws: TriggerSchedulerError.musicalContextRequired) {
                try fixture.scheduler.requireMusicalContext(fixture.musicalContext(nil))
            }
            #expect(try fixture.scheduler.requireMusicalContext(fixture.musicalContext(0)) == prepared)
            try fixture.observeMusical(.musical, 750, ticks: 480)
            #expect(try fixture.scheduler.requireMusicalContext(fixture.musicalContext(1)).observationSequence == 1)
            #expect(throws: TriggerSchedulerError.staleMusicalContext) {
                try fixture.scheduler.requireMusicalContext(fixture.musicalContext(0))
            }
            // A matching sequence is not enough when a current identity has moved on unobserved.
            try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
            #expect(throws: TriggerSchedulerError.staleMusicalContext) {
                try fixture.scheduler.requireMusicalContext(fixture.musicalContext(1))
            }
            try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 1_000_000)), 750)
            let current = try fixture.scheduler.requireMusicalContext(fixture.musicalContext(2))
            #expect(current.clock.map.revision == (try Generation(2)))
        }

        @Test func musicalObservationRaisesTheExistingClockFloor() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            let handle = try fixture.submit(fixture.stamp("trg.floor", arrival: 100))
            try fixture.prepareMusical(0)
            #expect(try fixture.snapshot().horizon?.frame == 100)
            try fixture.observeMusical(.primary, 1_500)
            #expect(try fixture.snapshot().latestAnchor == (try fixture.anchor(1_500)))
            #expect(try fixture.snapshot().horizon?.frame == 1_500)
            try fixture.observeMusical(.musical, 3_000, ticks: 1_920)
            let raised = try fixture.snapshot()
            // The clock keeps only the physical part; musical history stays in the timeline.
            #expect(raised.latestAnchor == (try fixture.anchor(3_000)) && raised.horizon?.frame == 3_000)
            #expect(fixture.scheduler.musicalSummary?.latestPrimary == (try fixture.anchor(3_000, ticks: 1_920)))
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(handle, at: 2_999) }
            #expect(try fixture.snapshot() == raised && fixture.scheduler.pendingCount == 1)
            try fixture.commit(handle, at: 3_000)
            #expect(try fixture.drainOne(handle).frame == 3_000)
        }

        @Test func physicalSampleProgressSurvivesRejectedMusicalObservation() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            let prepared = try #require(fixture.scheduler.musicalSummary)
            let handle = try fixture.submit(fixture.stamp("trg.sample", .sample(atFrame: 4_000), arrival: 10))
            #expect(throws: MusicalTimingError.observationGap) {
                try fixture.observeMusical(.primary, 3_000, sequence: 5)
            }
            // Independent physical progress remains valid and never extends musical coverage.
            try fixture.observe(3_000, host: 1_500_000)
            #expect(fixture.scheduler.musicalSummary == prepared)
            try fixture.commit(handle, at: 3_001)
            let outcome = try fixture.drainOne(handle)
            #expect(outcome.result == .fired && outcome.frame == 4_000 && outcome.musicalMap == nil)
            try outcome.validateMediaShape()
            let progressed = try fixture.snapshot()
            #expect(throws: SchedulerClockError.invalidAnchor) { try fixture.observeMusical(.primary, 2_000) }
            #expect(try fixture.scheduler.musicalSummary == prepared && fixture.snapshot() == progressed)
            try fixture.observeMusical(.primary, 3_000)
            #expect(fixture.scheduler.musicalSummary?.observationSequence == 1)
            #expect(try fixture.snapshot() == progressed)
        }
    }
}

extension ControlContractTests.SchedulerMusicalLifecycle {
    @Test func preparationAcceptsAnAnchorOlderThanTheLatestPhysicalObservation() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.observe(3_000, host: 1_500_000)
        let physical = try fixture.snapshot()
        try fixture.prepareMusical(1_500)
        let prepared = try #require(fixture.scheduler.musicalSummary)
        // The clock is untouched; the timeline validated the older anchor against the genuine baseline.
        #expect(try fixture.snapshot() == physical)
        #expect(try prepared.sample == physical.baseline && prepared.firstAnchor == fixture.anchor(1_500, ticks: 0))
        #expect(prepared.latestPrimary.sample.frame <= physical.latestAnchor?.sample.frame ?? .min)
    }

    @Test func secondPreparationIsRefusedBeforeClockValidation() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        try fixture.observe(3_000, host: 1_500_000)
        let before = try fixture.admissionState()
        // A stale anchor must not mask the identity of the refusal; a newer one must not move the clock.
        #expect(throws: TriggerSchedulerError.musicalAlreadyPrepared) { try fixture.prepareMusical(1_000) }
        #expect(throws: TriggerSchedulerError.musicalAlreadyPrepared) { try fixture.prepareMusical(4_500) }
        #expect(try fixture.admissionState() == before)
    }

    @Test func preparationWithoutPhysicalObservationEstablishesTheBaseline() throws {
        var fixture = try SchedulerFixture(capacity: 1, anchored: false)
        #expect(try fixture.snapshot().baseline == nil)
        try fixture.prepareMusical(1_500)
        let snapshot = try fixture.snapshot()
        let physical = ClockAnchor(sample: try fixture.sample(1_500), host: .init(ticks: 750_000))
        #expect(snapshot.baseline?.anchor == physical && snapshot.latestAnchor == physical)
        #expect(fixture.scheduler.musicalSummary?.sample == snapshot.baseline)
    }

    @Test func locateResetAcceptsAnAnchorCapturedBeforeTheLatestPhysicalObservation() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        try fixture.observe(3_000, host: 1_500_000)
        let physical = try fixture.snapshot()
        try fixture.ledger.bump(SchedulerFixture.transport, reason: .locate(ticks: 960))
        let reset = SchedulerMusicalReset(anchor: try fixture.anchor(1_500, ticks: 960), map: try fixture.map(),
                                          sequence: 1)
        try fixture.scheduler.resetMusical(reset, ledger: fixture.ledger)
        #expect(try fixture.snapshot() == physical)
        #expect(fixture.scheduler.musicalSummary?.firstAnchor == reset.anchor)
        #expect(fixture.scheduler.musicalSummary?.sample == physical.baseline)
    }

    @Test func restartResetAcceptsTheRestartStartAfterLaterPhysicalObservations() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        try fixture.observeMusical(.primary, 4_800)
        try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
        try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart)
        try fixture.ledger.recordClockRestart(.init(start: fixture.sample(0), host: .init(ticks: 10_000_000),
                                                    previousFrame: 4_800))
        try fixture.observe(0, host: 10_000_000)
        try fixture.observe(480, host: 10_240_000)
        let physical = try fixture.snapshot()
        // No loop: the timeline derives 4_800 frames x 0.64 = 3_072 ticks from the old history.
        let reset = SchedulerMusicalReset(anchor: try fixture.anchor(0, host: 10_000_000, ticks: 3_072),
                                          map: try fixture.map(), sequence: 2)
        try fixture.scheduler.resetMusical(reset, ledger: fixture.ledger)
        let summary = try #require(fixture.scheduler.musicalSummary)
        #expect(try fixture.snapshot() == physical)
        #expect(summary.sample == physical.baseline && summary.firstAnchor == reset.anchor)
        #expect(summary.clock.musical.ticks == 3_072 && summary.observationSequence == 2)
    }
}

/// D1: restart reset delegation. The scheduler never computes restart ticks; the timeline derives
/// them from its old history, so only the position that history implies is accepted.
extension SchedulerFixture {
    /// Records a completed wake restart starting at frame 0 / host 10_000_000.
    mutating func restart(previousFrame: Int64) throws {
        try ledger.bump(ledger.primaryClock, reason: .wake)
        try ledger.bump(Self.transport, reason: .clockRestart)
        try ledger.recordClockRestart(.init(start: sample(0), host: .init(ticks: 10_000_000),
                                            previousFrame: previousFrame))
    }

    mutating func resetAfterRestart(ticks: Int64, map: MusicalMap? = nil) throws {
        let reset = SchedulerMusicalReset(anchor: try anchor(0, host: 10_000_000, ticks: ticks),
                                          map: try map ?? self.map(),
                                          sequence: (scheduler.musicalSummary?.observationSequence ?? 0) + 1)
        try scheduler.resetMusical(reset, ledger: ledger)
    }
}

extension ControlContractTests.SchedulerMusicalLifecycle {
    /// Loop 0..1920 wraps at frame 3_000. The pass is chosen at the rounded wrap before ticks are rounded.
    @Test(arguments: [(Int64(2_999), Int64(1_919)), (3_000, 0), (3_001, 1)])
    func restartUsesRoundedWrapBeforeTickRounding(previous: Int64, ticks: Int64) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
        try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
        try fixture.observeMusical(.musical, 3_600, ticks: 384, pass: 1)
        try fixture.restart(previousFrame: previous)
        for wrong in [ticks + 1, ticks == 0 ? 1_920 : ticks - 1] {
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.invalidContext) { try fixture.resetAfterRestart(ticks: wrong) }
            #expect(try fixture.admissionState() == before)
        }
        try fixture.resetAfterRestart(ticks: ticks)
        let summary = try #require(fixture.scheduler.musicalSummary)
        // A current-loop restart: pass 0 of the new epoch, loop retained, old history discarded.
        #expect(summary.clock.musical.ticks == ticks && summary.clock.musical.loopIteration == 0)
        #expect(try summary.loop == LoopRange(startTicks: 0, endTicks: 1_920) && summary.historyCount == 1)
        #expect(try summary.firstAnchor == fixture.anchor(0, host: 10_000_000, ticks: ticks))
        #expect(summary.observationSequence == 3 && summary.pinCount == 0)
    }

    /// Fractional loop 0..3 (4.6875 frames) wraps at rounded frame 5. At frame 4 the tick 2.56 already
    /// rounds to the loop end 3, yet the pass is still 0: resetting to the loop start must be refused.
    /// Rounding ticks first and normalizing 3 to 0 would accept tick 0 there. At the wrap itself, tick 0 is correct.
    @Test(arguments: [(Int64(4), Int64(3)), (5, 0)])
    func restartBeforeTheRoundedWrapKeepsTheLoopEndTick(previous: Int64, ticks: Int64) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        let loop = try LoopRange(startTicks: 0, endTicks: 3)
        try fixture.prepareMusical(0, loop: loop)
        try fixture.observeMusical(.primary, 4)
        try fixture.observeMusical(.wrap, 5, ticks: 0, pass: 1)
        try fixture.restart(previousFrame: previous)
        let before = try fixture.admissionState()
        for wrong in Int64(0)...3 where wrong != ticks {
            #expect(throws: MusicalTimingError.invalidContext) { try fixture.resetAfterRestart(ticks: wrong) }
            #expect(try fixture.admissionState() == before)
        }
        try fixture.resetAfterRestart(ticks: ticks)
        let summary = try #require(fixture.scheduler.musicalSummary)
        #expect(summary.clock.musical.ticks == ticks && summary.clock.musical.loopIteration == 0)
        #expect(summary.loop == loop && summary.historyCount == 1 && summary.pinCount == 0)
        #expect(try summary.firstAnchor == fixture.anchor(0, host: 10_000_000, ticks: ticks))
        #expect(summary.observationSequence == (before.music?.observationSequence ?? 0) + 1)
        #expect(try summary.sample == fixture.snapshot().baseline && fixture.scheduler.pendingCount == 0)
    }

    @Test func failedRestartPositionPreservesOldTimeline() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        try fixture.observeMusical(.musical, 3_000, ticks: 1_920)
        let pinned = try fixture.submitMusical(fixture.stamp("trg.pinned", .musical(atTicks: 2_400)))
        try fixture.restart(previousFrame: 3_000)
        let before = try fixture.admissionState()
        #expect(throws: MusicalTimingError.pinsOutstanding) { try fixture.resetAfterRestart(ticks: 1_920) }
        #expect(try fixture.admissionState() == before && before.music?.pinCount == 1)
        #expect(try fixture.scheduler.cancelStale(ledger: fixture.ledger) == [pinned])
        #expect(try fixture.drainOne(pinned) == TriggerOutcome(trigger: pinned.trigger, result: .cancelled,
                                                               stale: .generation(fixture.ledger.primaryClock)))
        let quiescent = try fixture.admissionState()
        #expect(quiescent.music?.pinCount == 0 && quiescent.music?.historyCount == 2 && quiescent.pending == 0)
        for wrong: Int64 in [1_919, 1_921] {
            #expect(throws: MusicalTimingError.invalidContext) { try fixture.resetAfterRestart(ticks: wrong) }
            #expect(try fixture.admissionState() == quiescent)
        }
        try fixture.resetAfterRestart(ticks: 1_920)
        let summary = try #require(fixture.scheduler.musicalSummary)
        #expect(summary.clock.musical.ticks == 1_920 && summary.observationSequence == 2)
        #expect(try summary.historyCount == 1 && summary.sample == fixture.snapshot().baseline)
    }

    @Test func restartUsesOldMapAndNewPhysicalBaseline() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        try fixture.prepareMusical(0)
        try fixture.observeMusical(.primary, 4_500) // Old history covers previousFrame.
        try fixture.restart(previousFrame: 4_500)
        let revision = try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
        let slow = try fixture.map(microsPerQuarter: 1_000_000)
        let before = try fixture.admissionState()
        // The position is read through the OLD map: 4_500 x 0.64 = 2_880, never 4_500 x 0.32 = 1_440.
        #expect(throws: MusicalTimingError.invalidContext) { try fixture.resetAfterRestart(ticks: 1_440, map: slow) }
        #expect(try fixture.admissionState() == before)
        try fixture.resetAfterRestart(ticks: 2_880, map: slow)
        let summary = try #require(fixture.scheduler.musicalSummary)
        let physical = try fixture.snapshot()
        #expect(summary.clock.musical.ticks == 2_880 && summary.clock.map == slow && slow.revision == revision)
        #expect(summary.sample == physical.baseline && physical.baseline?.anchor.sample.frame == 0)
        #expect(physical.baseline?.anchor.host.ticks == 10_000_000)
        #expect(summary.sample != before.music?.sample)
    }
}
