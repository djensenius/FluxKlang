import Testing
@testable import FluxKlang

/// Drift fixture: the timeline's own latest primary (frame 100, host 40_000) and the
/// scheduler clock's newer physical anchor (frame 120, host 45_000) map hosts differently.
private extension SchedulerFixture {
    static func drifted() throws -> SchedulerFixture {
        var fixture = try SchedulerFixture(capacity: 2)
        try fixture.prepareMusical(0, history: 2)
        try fixture.observeMusical(.musical, 60, ticks: 38)
        try fixture.observeMusical(.primary, at: fixture.anchor(100, host: 40_000))
        try fixture.observe(120, host: 45_000)
        return fixture
    }

    func grid(_ id: StaticString, originHost: UInt64, arrival: Int64 = 200) -> TriggerStamp {
        musicalStamp(id, .grid(ticks: 1), originHost: originHost, arrival: arrival)
    }
}

extension ControlContractTests {
    struct SchedulerMusicalObservations {
        @Test func hostOriginUsesSchedulerClocksLatestPhysicalAnchor() throws {
            var fixture = try SchedulerFixture.drifted()
            // Through the clock's latest anchor host 35_000 is frame 100 (63.6 ticks -> grid 64);
            // the timeline's own primary would have said frame 90 (57.2 -> 58).
            let handle = try fixture.submitMusical(fixture.grid("trg.latest", originHost: 35_000))
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 64)))
        }

        @Test func newerPhysicalAnchorDoesNotExtendMusicalCoverage() throws {
            var fixture = try SchedulerFixture.drifted()
            let stamp = fixture.grid("trg.cover", originHost: 45_000)
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.uncoveredOrigin) { try fixture.submitMusical(stamp) }
            #expect(try fixture.admissionState() == before)
            try fixture.observeMusical(.primary, at: fixture.anchor(120, host: 45_000))
            let handle = try fixture.submitMusical(stamp)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 77)))
        }

        @Test func physicalPayloadDoesNotBecomeMusicalHistory() throws {
            var fixture = try SchedulerFixture.drifted()
            let music = fixture.scheduler.musicalSummary
            let payload = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 999, loopIteration: 99)
            try fixture.observe(140, host: 50_000, musical: payload)
            #expect(fixture.scheduler.musicalSummary == music)
            let physical = ClockAnchor(sample: try fixture.sample(140), host: .init(ticks: 50_000))
            #expect(try fixture.snapshot().latestAnchor == physical)
            // Host 30_000 is frame 100 through the payload-free latest anchor: pass 0, never pass 99.
            let handle = try fixture.submitMusical(fixture.grid("trg.payload", originHost: 30_000))
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 64)))
        }

        @Test(arguments: [UInt64(29_000), 40_001, 45_001])
        func latestPhysicalConversionRefusalPreservesAdmissionState(originHost: UInt64) throws {
            var fixture = try SchedulerFixture.drifted()
            let before = try fixture.admissionState()
            #expect(throws: MusicalTimingError.uncoveredOrigin) {
                try fixture.submitMusical(fixture.grid("trg.refused", originHost: originHost))
            }
            #expect(try fixture.admissionState() == before)
            #expect(fixture.scheduler.drain().isEmpty)
            let handle = try fixture.submitMusical(fixture.grid("trg.refused", originHost: 35_000))
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 64)))
            #expect(try fixture.snapshot().horizon?.frame == 200)
        }
    }
}

/// E1: an observation that would strand a pending pin is refused atomically by the timeline's
/// refresh; the scheduler changes no loop, sequence, coverage, pin, reservation, outcome or clock.
extension ControlContractTests.SchedulerMusicalObservations {
    private static func pinned(running: Bool, target: TriggerTarget, originHost: UInt64 = 0,
                               primary: Int64 = 100) throws -> (SchedulerFixture, TriggerHandle) {
        var fixture = try SchedulerFixture(capacity: 2)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920), running: running)
        try fixture.observeMusical(.primary, primary)
        let handle = try fixture.submitMusical(fixture.musicalStamp("trg.pin", target, originHost: originHost,
                                                                    arrival: primary))
        return (fixture, handle)
    }

    private static func expectAtomicRefusal(_ fixture: inout SchedulerFixture, _ handle: TriggerHandle,
                                            _ observation: MusicalObservation, at frame: Int64,
                                            throwing error: MusicalTimingError = .outsideLoop) throws {
        let before = try fixture.admissionState()
        let music = fixture.scheduler.pendingMusic(handle)
        #expect(throws: error) { try fixture.observeMusical(observation, frame) }
        #expect(try fixture.admissionState() == before && fixture.scheduler.pendingMusic(handle) == music)
        #expect(fixture.scheduler.drain().isEmpty)
    }

    @Test func futurePinStrandingObservationIsAtomic() throws {
        var (fixture, handle) = try Self.pinned(running: true, target: .musical(atTicks: 1_800))
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 1_800)))
        try Self.expectAtomicRefusal(&fixture, handle, .loop(LoopRange(startTicks: 0, endTicks: 960)), at: 200)
        try fixture.commitMusical(handle, at: 200)
        #expect(try fixture.drainOne(handle).frame == 2_813)
    }

    @Test(arguments: [(Int64(0), Int64(960)), (1_900, 3_000)])
    func stoppedFuturePinRejectsInvalidLoopChanges(start: Int64, end: Int64) throws {
        var (fixture, handle) = try Self.pinned(running: false, target: .musical(atTicks: 1_800))
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 1_800)))
        let loop = try LoopRange(startTicks: start, endTicks: end)
        try Self.expectAtomicRefusal(&fixture, handle, .loop(loop), at: 200)
        // A loop change that still admits the pinned occurrence is accepted and keeps the pin.
        try fixture.observeMusical(.loop(LoopRange(startTicks: 0, endTicks: 3_840)), 200)
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 1_800)))
        #expect(fixture.scheduler.musicalSummary?.pinCount == 1)
    }

    @Test func loopRemovalSucceedsAfterTerminalPinRelease() throws {
        // Origin ticks 1_300: the next 1_280 grid line is past the loop end, so the timeline
        // forward-chooses the next pass's start. Without a loop that future pass has no history.
        var (fixture, handle) = try Self.pinned(running: true, target: .grid(ticks: 1_280), originHost: 1_015_625,
                                                primary: 2_100)
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 1, ticks: 0)))
        try Self.expectAtomicRefusal(&fixture, handle, .loop(nil), at: 2_200, throwing: .historyUnavailable)
        try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange)
        try fixture.commitMusical(handle, at: 2_200)
        #expect(try fixture.drainOne(handle).result == .cancelled)
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
        try fixture.observeMusical(.loop(nil), 2_200)
        #expect(fixture.scheduler.musicalSummary?.loop == nil)
    }

    @Test func rejectedTransitionSequenceCannotResolvePendingMusic() throws {
        var (fixture, handle) = try Self.pinned(running: true, target: .musical(atTicks: 1_800))
        let other = try fixture.submitMusical(fixture.musicalStamp("trg.other", .musical(atTicks: 960),
                                                                   originHost: 0, arrival: 100))
        let sequence = try #require(fixture.scheduler.musicalSummary?.observationSequence)
        try Self.expectAtomicRefusal(&fixture, handle, .loop(LoopRange(startTicks: 0, endTicks: 960)), at: 200)
        // The refused observation's sequence never became current: naming it is a strict diagnostic.
        try fixture.commitMusical(handle, at: 200, sequence: sequence + 1)
        #expect(try fixture.drainOne(handle) == TriggerOutcome(trigger: handle.trigger, result: .dropped,
                                                               reason: .invalidTiming))
        try fixture.commitMusical(other, at: 200, sequence: sequence)
        #expect(try fixture.drainOne(other).frame == 1_500)
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0)
    }
}
