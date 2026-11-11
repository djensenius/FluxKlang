import Foundation
import Testing
@testable import FluxKlang

/// Test-local composition helpers; no shared TestSupport or production escape hatches.
struct SchedulerFixture {
    static let primary = ClockID(validated: "smp.core")
    static let musical = ClockID(validated: "mus.core")
    static let transport = GenerationKey(.transport, musical)
    static let context = GenerationKey(.context, GenerationSubject(validated: "context.core"))
    static let source = GenerationKey(.source, StreamID(validated: "source.core"))
    static let action = ActionID(validated: "action.core")
    static let timebase = HostTimebase(numer: 125, denom: 3)

    var ledger: GenerationLedger
    var readiness = ActionReadiness()
    var scheduler: TriggerScheduler

    init(capacity: Int = 8, anchored: Bool = true, frame: Int64 = 0,
         host: UInt64 = 0, rate: Int = 48_000) throws {
        ledger = try GenerationLedger(primaryClock: Self.primary, musicalClock: Self.musical, nominalRate: rate,
                                      declaring: [Self.context, Self.source])
        scheduler = try TriggerScheduler(ledger: ledger, timebase: Self.timebase, outcomeCapacity: capacity)
        try prepare()
        if anchored { try observe(frame, host: host) }
    }

    mutating func prepare() throws {
        try readiness.transition(Self.action, to: .preparing)
        try readiness.markReady(Self.action, preparedAgainst: [
            .init(key: Self.source, generation: #require(ledger.generation(Self.source)))
        ], ledger: ledger)
    }

    func sample(_ frame: Int64, generation: Generation? = nil) throws -> SampleStamp {
        try SampleStamp(clock: Self.primary, generation: generation ?? #require(ledger.generation(ledger.primaryClock)),
                        frame: frame)
    }

    func stamp(_ id: StaticString, _ target: TriggerTarget = .asap, policy: LatePolicy = .drop,
               arrival: Int64 = 0, requiring extra: [GenerationKey] = []) -> TriggerStamp {
        var keys = [ledger.primaryClock, Self.context] + extra
        if target.isMusical, !keys.contains(Self.transport) { keys.append(Self.transport) }
        return TriggerStamp(id: TriggerID(validated: id), action: Self.action, originHost: .init(ticks: 0),
                            horizonFrame: arrival, requires: keys.map {
                                .init(key: $0, generation: ledger.generation($0) ?? .initial)
                            }, target: target, latePolicy: policy)
    }

    func replacingRequirements(_ stamp: TriggerStamp, with requirements: [GenerationRequirement]) -> TriggerStamp {
        TriggerStamp(id: stamp.id, action: stamp.action, originHost: stamp.originHost,
                     horizonFrame: stamp.horizonFrame, requires: requirements, target: stamp.target,
                     latePolicy: stamp.latePolicy, retroactiveMs: stamp.retroactiveMs,
                     stoppedPolicy: stamp.stoppedPolicy, loopIteration: stamp.loopIteration)
    }

    mutating func submit(_ stamp: TriggerStamp) throws -> TriggerHandle {
        try scheduler.submit(stamp, session: scheduler.currentToken, ledger: ledger, readiness: readiness)
    }

    mutating func commit(_ handle: TriggerHandle, at frame: Int64,
                         generation: Generation? = nil, rate: Int? = nil) throws {
        try scheduler.commit(handle, at: sample(frame, generation: generation), nominalRate: rate ?? ledger.nominalRate,
                             ledger: ledger, readiness: readiness)
    }

    mutating func observe(_ frame: Int64, host: UInt64, musical: MusicalStamp? = nil) throws {
        let anchor = try ClockAnchor(sample: sample(frame), host: .init(ticks: host), musical: musical)
        try scheduler.observe(anchor, nominalRate: ledger.nominalRate, timebase: Self.timebase, ledger: ledger)
    }

    func snapshot() throws -> SchedulerClock.Snapshot { try scheduler.snapshot(ledger: ledger) }

    mutating func drainOne(_ handle: TriggerHandle) throws -> TriggerOutcome {
        let outcomes = scheduler.drain()
        #expect(outcomes.count == 1)
        let only = try #require(outcomes.first)
        #expect(only.handle == handle)
        return only.outcome
    }
}

private struct SampleTimingCase: Sendable {
    let target: TriggerTarget
    let policy: LatePolicy
    let result: OutcomeResult
    let assigned: Int64
    let frame: Int64?
    var offset: Int64 = 0
}

// M4's original six cases, not six substitutes selected by aggregate test counts.
private let sampleTimingCases: [SampleTimingCase] = [
    .init(target: .sample(atFrame: 1_000), policy: .drop, result: .dropped, assigned: 1_000, frame: nil),
    .init(target: .sample(atFrame: 1_000), policy: .fireLate(maxLatenessMs: 10),
          result: .firedLate, assigned: 1_000, frame: 1_100),
    .init(target: .sample(atFrame: 1_000), policy: .joinInProgress(maxLatenessMs: 10),
          result: .joined, assigned: 1_000, frame: 1_100, offset: 100),
    .init(target: .sample(atFrame: 1_000), policy: .fireLate(maxLatenessMs: 1),
          result: .dropped, assigned: 1_000, frame: nil),
    .init(target: .asap, policy: .drop, result: .fired, assigned: 1_100, frame: 1_100),
    .init(target: .sample(atFrame: 2_000), policy: .drop, result: .fired, assigned: 2_000, frame: 2_000)
]

extension ControlContractTests {
    struct Triggers {
        @Test func stalePrimaryCannotRaiseNewHorizonButStaleSecondaryMust() throws {
            var fixture = try SchedulerFixture()
            let old = fixture.stamp("trg.old", arrival: 1_000)
            let next = try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
            try fixture.ledger.bump(SchedulerFixture.transport, reason: .clockRestart)
            try fixture.ledger.recordClockRestart(.init(start: fixture.sample(0), host: .init(ticks: 0),
                                                        previousFrame: 999))
            let oldHandle = try fixture.submit(old)
            #expect(try fixture.snapshot().horizon == nil)
            #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 1)
            let fresh = try fixture.submit(fixture.stamp("trg.fresh", arrival: 10))
            let secondary = GenerationKey(.source, StreamID(validated: "source.secondary"))
            try fixture.ledger.declare(secondary)
            let stale = fixture.stamp("trg.secondary", arrival: 40, requiring: [secondary])
            try fixture.ledger.bump(secondary, reason: .sourceLost)
            let secondaryHandle = try fixture.submit(stale)
            let queued = fixture.scheduler.drain()
            #expect(queued.map(\.handle) == [oldHandle, secondaryHandle])
            #expect(queued.map(\.outcome.result) == [.rejectedStale, .rejectedStale])
            #expect(queued.map(\.outcome.stale) == [.generation(fixture.ledger.primaryClock), .generation(secondary)])
            for item in queued { try item.outcome.validateMediaShape() }
            let before = try fixture.snapshot()
            #expect(before.horizon == (try fixture.sample(40, generation: next)))
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(fresh, at: 30) }
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 1)
            try fixture.observe(0, host: 0)
            try fixture.commit(fresh, at: 40)
            #expect(try fixture.drainOne(fresh).frame == 40)
        }

        @Test func capacityRefusesSynchronouslyWithoutAnOutcome() throws {
            var fixture = try SchedulerFixture(capacity: 2)
            let firstStamp = fixture.stamp("trg.first", arrival: 10)
            let first = try fixture.submit(firstStamp)
            let unknown = GenerationKey(.source, StreamID(validated: "source.unknown"))
            let stale = try fixture.submit(fixture.stamp("trg.stale", arrival: 20, requiring: [unknown]))
            let before = try fixture.snapshot()
            #expect(throws: TriggerSessionError.outcomeCapacity) {
                try fixture.submit(fixture.stamp("trg.third", arrival: .max))
            }
            #expect(try fixture.snapshot() == before)
            #expect(fixture.scheduler.pendingCount == 1 && fixture.scheduler.reservedOutcomeCount == 2)
            #expect(try fixture.drainOne(stale).result == .rejectedStale)
            let third = try fixture.submit(fixture.stamp("trg.third", arrival: 21))
            #expect(throws: TriggerSessionError.duplicateID) { try fixture.submit(firstStamp) }
            #expect(fixture.scheduler.drain().isEmpty)
            try fixture.commit(first, at: 21)
            try fixture.commit(third, at: 21)
            #expect(fixture.scheduler.drain().map(\.handle) == [first, third])
            #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 0)
            #expect(throws: TriggerSessionError.duplicateID) { try fixture.submit(firstStamp) }
        }

        @Test(arguments: sampleTimingCases)
        fileprivate func latenessIsJudgedAtCommitNotArrival(item: SampleTimingCase) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            let stamp = fixture.stamp("trg.commit", item.target, policy: item.policy, arrival: 900)
            let handle = try fixture.submit(stamp)
            #expect(fixture.scheduler.drain().isEmpty && fixture.scheduler.pendingCount == 1)
            try fixture.commit(handle, at: 1_100)
            #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 1)
            let outcome = try fixture.drainOne(handle)
            #expect(outcome.result == item.result && outcome.assignedFrame == item.assigned)
            #expect(outcome.frame == item.frame && outcome.startOffsetFrames == item.offset)
            #expect(outcome.reason == (item.result == .dropped ? .late : nil))
            #expect(outcome.stale == nil && outcome.musicalMap == nil)
            #expect(outcome.frame.map { $0 >= 1_100 } ?? true)
            try outcome.validateMediaShape()
            let record = try TriggerOutcomeV1Record.make(outcome, seq: 1)
            #expect(record.startOffsetFrames == (item.offset == 0 ? nil : item.offset) && record.frame == item.frame)
            #expect(record.assignedFrame == item.assigned && record.reason == (item.result == .dropped ? "late" : nil))
        }

        @Test func horizonProgressUsesThePrimaryGenerationOnly() throws {
            var fixture = try SchedulerFixture()
            let first = try fixture.submit(fixture.stamp("trg.source", arrival: 900,
                                                        requiring: [SchedulerFixture.source]))
            let second = try fixture.submit(fixture.stamp("trg.other", arrival: 900))
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(second, at: 800) }
            try fixture.ledger.bump(SchedulerFixture.source, reason: .sourceLost)
            try fixture.commit(first, at: 1_200)
            let cancelled = try fixture.drainOne(first)
            #expect(cancelled.result == .cancelled && cancelled.stale == .generation(SchedulerFixture.source))
            #expect(throws: SchedulerClockError.regressingHorizon) { try fixture.commit(second, at: 1_100) }
            try fixture.ledger.bump(fixture.ledger.primaryClock, reason: .wake)
            #expect(throws: ClockMapError.staleSampleGeneration) {
                try fixture.commit(second, at: 1_300, generation: .initial)
            }
            #expect(try fixture.snapshot().horizon == nil)
            try fixture.commit(second, at: 10)
            #expect(try fixture.drainOne(second).result == .cancelled)
            #expect(try fixture.snapshot().horizon?.frame == 10)
            #expect(try fixture.snapshot().baseline == nil && fixture.ledger.hasRestartObligations)
        }

        @Test func undeclaredDependenciesNeverFireAndDeclaredScopesCancel() throws {
            for kind: GenerationKind in [.context, .source, .cancelScope] {
                var fixture = try SchedulerFixture(capacity: 1)
                let unknown = GenerationKey(kind, GenerationSubject(validated: "dependency.unknown"))
                let handle = try fixture.submit(fixture.stamp("trg.unknown", requiring: [unknown]))
                #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 1)
                let outcome = try fixture.drainOne(handle)
                #expect(outcome.result == .rejectedStale && outcome.stale == .generation(unknown))
                try outcome.validateMediaShape()
                #expect(throws: TriggerSessionError.notPending) { try fixture.commit(handle, at: 1) }
            }
            var fixture = try SchedulerFixture(capacity: 1)
            let scope = GenerationKey(.cancelScope, GenerationSubject(validated: "scope.scene"))
            try fixture.ledger.declare(scope)
            let handle = try fixture.submit(fixture.stamp("trg.cancel", .sample(atFrame: 4_000), requiring: [scope]))
            try fixture.ledger.bump(scope, reason: .userCancel)
            try fixture.commit(handle, at: 1_000)
            let outcome = try fixture.drainOne(handle)
            #expect(outcome.result == .cancelled && outcome.stale == .generation(scope))
            try outcome.validateMediaShape()
        }

        @Test func precedenceIsCancelledThenNotReadyWithoutResolvingTheTarget() throws {
            var fixture = try SchedulerFixture(anchored: false)
            fixture.readiness = ActionReadiness()
            // Keep both original musical cancellations, but do not counterfeit ready-origin coverage.
            let first = try fixture.submit(fixture.stamp("trg.both", .musical(atTicks: 0)))
            let second = try fixture.submit(fixture.stamp("trg.also-cancelled", .musical(atTicks: 0)))
            try fixture.ledger.bump(SchedulerFixture.transport, reason: .locate(ticks: 0))
            for handle in [first, second] {
                try fixture.commit(handle, at: 1_000)
                let outcome = try fixture.drainOne(handle)
                #expect(outcome.result == .cancelled && outcome.stale == .generation(SchedulerFixture.transport))
                try outcome.validateMediaShape()
            }
            // Genuinely NONcancelled notReady, with neither physical nor musical resolution available.
            let unready = try fixture.submit(fixture.stamp("trg.unready", .grid(ticks: 960)))
            try fixture.commit(unready, at: 1_000)
            let outcome = try fixture.drainOne(unready)
            #expect(outcome == TriggerOutcome(trigger: unready.trigger, result: .dropped, reason: .notReady))
            try outcome.validateMediaShape()
            #expect(try fixture.snapshot().baseline == nil)
        }

        @Test func triggerShapeValidation() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            let mapKey = GenerationKey(.musicalMap, SchedulerFixture.musical)
            var dropRetro = fixture.stamp("trg.shape", .grid(ticks: 3_840), arrival: .max)
            dropRetro.retroactiveMs = 50
            var excessiveRetro = fixture.stamp("trg.shape", .grid(ticks: 3_840),
                                               policy: .fireLate(maxLatenessMs: 40), arrival: .max)
            excessiveRetro.retroactiveMs = 50
            let cases: [(TriggerStamp, TriggerValidationError)] = [
                (fixture.stamp("trg.shape", arrival: .max, requiring: [mapKey]), .musicalMapDependency),
                (fixture.stamp("trg.shape", arrival: .max,
                               requiring: [SchedulerFixture.source, SchedulerFixture.source]),
                 .duplicateRequirement(SchedulerFixture.source)),
                (dropRetro, .invalidRetroactive(50)), (excessiveRetro, .invalidRetroactive(50))
            ]
            let before = try fixture.snapshot()
            for (stamp, error) in cases {
                #expect(throws: error) { try fixture.submit(stamp) }
                #expect(try fixture.snapshot() == before)
                #expect(fixture.scheduler.reservedOutcomeCount == 0 && fixture.scheduler.drain().isEmpty)
            }
            _ = try fixture.submit(fixture.stamp("trg.shape"))
        }
    }
}

extension ControlContractTests.Triggers {
    @Test func fullRangeSampleLatenessKeepsItsPolicy() throws {
        for policy: LatePolicy in [.drop, .fireLate(maxLatenessMs: 1_000), .joinInProgress(maxLatenessMs: 1_000)] {
            for horizon: Int64 in [0, .max] {
                var fixture = try SchedulerFixture(capacity: 1)
                let handle = try fixture.submit(fixture.stamp("trg.minimum", .sample(atFrame: .min), policy: policy))
                try fixture.commit(handle, at: horizon)
                let outcome = try fixture.drainOne(handle)
                #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .late,
                                                   assignedFrame: .min))
                try outcome.validateMediaShape()
            }
        }
        var fixture = try SchedulerFixture(capacity: 1)
        let handle = try fixture.submit(fixture.stamp("trg.maximum", .sample(atFrame: .max),
            policy: .nextBoundary(gridTicks: 960), requiring: [SchedulerFixture.transport]))
        try fixture.commit(handle, at: .max)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome.result == .fired && outcome.assignedFrame == .max && outcome.frame == .max)
        try outcome.validateMediaShape()
        // V10's successful musical fallback is covered in +SchedulingValidation
        // (fullRangeSampleFallbackSucceedsFromTheMinimumFrame); no default frame is substituted here.
    }

    @Test(arguments: [Int64.min, -1, 0, Int64.max])
    func signedFrameOriginsAndMaximumHostRemainLegal(frame: Int64) throws {
        for target: TriggerTarget in [.sample(atFrame: frame), .asap] {
            var fixture = try SchedulerFixture(capacity: 1, frame: frame, host: .max)
            let handle = try fixture.submit(fixture.stamp("trg.signed", target, arrival: frame))
            try fixture.commit(handle, at: frame)
            let outcome = try fixture.drainOne(handle)
            #expect(outcome.result == .fired && outcome.frame == frame && outcome.assignedFrame == frame)
            try outcome.validateMediaShape()
        }
    }

    @Test(arguments: [TriggerTarget.sample(atFrame: 4_000), .asap])
    func sampleAndASAPStillRequireCurrentContext(target: TriggerTarget) throws {
        var fixture = try SchedulerFixture(capacity: 1)
        let valid = fixture.stamp("trg.context", target)
        let missing = fixture.replacingRequirements(valid, with: valid.requires.filter { $0.key.kind != .context })
        let before = try fixture.snapshot()
        #expect(throws: TriggerValidationError.missingContext) { try fixture.submit(missing) }
        #expect(try fixture.snapshot() == before)
        #expect(fixture.scheduler.reservedOutcomeCount == 0 && fixture.scheduler.drain().isEmpty)
        let handle = try fixture.submit(valid)
        try fixture.ledger.bump(SchedulerFixture.context, reason: .contextChange)
        try fixture.commit(handle, at: 3_001)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome.result == .cancelled && outcome.stale == .generation(SchedulerFixture.context))
        try outcome.validateMediaShape()
        var stale = try TriggerScheduler(ledger: fixture.ledger, timebase: SchedulerFixture.timebase,
                                         outcomeCapacity: 1)
        let staleHandle = try stale.submit(valid, session: stale.currentToken,
                                            ledger: fixture.ledger, readiness: fixture.readiness)
        let queued = stale.drain()
        #expect(queued.map(\.handle) == [staleHandle])
        #expect(queued.first?.outcome.result == .rejectedStale)
        #expect(queued.first?.outcome.stale == .generation(SchedulerFixture.context))
    }
}

private typealias OutcomeRefusal = TriggerOutcomeV1RecordRefusal

private func outcomeRefusal(_ outcome: TriggerOutcome, seq: Int = 1, note: String? = nil) -> OutcomeRefusal? {
    do {
        _ = try TriggerOutcomeV1Record.make(outcome, seq: seq, note: note)
        return nil
    } catch {
        return error
    }
}

private func staleOutcome(_ id: StaticString, _ result: OutcomeResult, _ kind: GenerationKind) -> TriggerOutcome {
    TriggerOutcome(trigger: TriggerID(validated: id), result: result,
                   stale: .generation(GenerationKey(kind, GenerationSubject(validated: "subject.example"))))
}

/// A golden `outcomeRecord` from a media contract example (`<example> seq <n>`), keys sorted, compact;
/// the table pins all 25 example outcome records.
private struct GoldenOutcome {
    let label: String
    let outcome: TriggerOutcome
    let seq: Int
    let note: String?
    let json: String

    init(_ label: String, _ outcome: TriggerOutcome, _ seq: Int, _ note: String?, _ json: String) {
        (self.label, self.outcome, self.seq, self.note, self.json) = (label, outcome, seq, note, json)
    }
}

private func goldenOutcomeRecords() throws -> [GoldenOutcome] {
    let map1 = Generation.initial, map2 = try Generation(2)
    func dispatched(_ id: StaticString, _ result: OutcomeResult, _ assigned: Int64, _ frame: Int64,
                    offset: Int64 = 0, map: Generation) -> TriggerOutcome {
        TriggerOutcome(trigger: TriggerID(validated: id), result: result, assignedFrame: assigned, frame: frame,
                       startOffsetFrames: offset, musicalMap: map)
    }
    func fired(_ id: StaticString, _ frame: Int64, map: Generation = .initial) -> TriggerOutcome {
        dispatched(id, .fired, frame, frame, map: map)
    }
    let late = TriggerOutcome(trigger: TriggerID(validated: "trg.4"), result: .dropped, reason: .late,
                              assignedFrame: 336_000)
    var held = staleOutcome("trg.1", .cancelled, .source)
    (held.assignedFrame, held.musicalMap) = (5, map1)
    func notReady(_ id: StaticString) -> TriggerOutcome {
        TriggerOutcome(trigger: TriggerID(validated: id), result: .dropped, reason: .notReady)
    }
    return [
        .init("01 seq 5", staleOutcome("trg.1", .cancelled, .sampleClock), 5, "Never re-targeted onto the new clock.",
         #"{"kind":"outcome","note":"Never re-targeted onto the new clock.","reason":"sampleClock","#
            + #""result":"cancelled","seq":5,"triggerId":"trg.1"}"#),
        .init("01 seq 11", staleOutcome("trg.2", .rejectedStale, .sampleClock), 11, nil,
         #"{"kind":"outcome","reason":"sampleClock","result":"rejectedStale","seq":11,"triggerId":"trg.2"}"#),
        .init("01 seq 13", fired("trg.3", 96_000), 13, nil, #"{"assignedFrame":96000,"frame":96000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":13,"triggerId":"trg.3"}"#),
        .init("02 seq 3", dispatched("trg.1", .joined, 96_000, 96_736, offset: 736, map: map1), 3, nil,
         #"{"assignedFrame":96000,"frame":96736,"kind":"outcome","musicalMap":1,"result":"joined","seq":3,"#
            + #""startOffsetFrames":736,"triggerId":"trg.1"}"#),
        .init("02 seq 5", fired("trg.2", 288_000), 5, nil, #"{"assignedFrame":288000,"frame":288000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":5,"triggerId":"trg.2"}"#),
        .init("02 seq 7", dispatched("trg.3", .firedLate, 312_000, 312_160, map: map1), 7, nil,
         #"{"assignedFrame":312000,"frame":312160,"kind":"outcome","musicalMap":1,"result":"firedLate","seq":7,"#
            + #""triggerId":"trg.3"}"#),
        .init("02 seq 9", late, 9, nil,
         #"{"assignedFrame":336000,"kind":"outcome","reason":"late","result":"dropped","seq":9,"triggerId":"trg.4"}"#),
        .init("02 seq 11", fired("trg.5", 384_000), 11, nil, #"{"assignedFrame":384000,"frame":384000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":11,"triggerId":"trg.5"}"#),
        .init("03 seq 8", fired("trg.1", 288_000), 8,
              "The wrap does not move the resolved target; nextBoundary advances it to bar 2 of iteration 1.",
         #"{"assignedFrame":288000,"frame":288000,"kind":"outcome","musicalMap":1,"note":"The wrap does not "#
            + #"move the resolved target; nextBoundary advances it to bar 2 of iteration 1.","result":"fired","#
            + #""seq":8,"triggerId":"trg.1"}"#),
        .init("03 seq 14", staleOutcome("trg.2", .cancelled, .transport), 14, nil,
         #"{"kind":"outcome","reason":"transport","result":"cancelled","seq":14,"triggerId":"trg.2"}"#),
        .init("03 seq 21", fired("trg.3", 306_000), 21, nil, #"{"assignedFrame":306000,"frame":306000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":21,"triggerId":"trg.3"}"#),
        .init("04 seq 3", fired("trg.1", 96_000), 3, nil, #"{"assignedFrame":96000,"frame":96000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":3,"triggerId":"trg.1"}"#),
        .init("04 seq 7", fired("trg.2", 268_800, map: map2), 7, nil, #"{"assignedFrame":268800,"frame":268800,"#
            + #""kind":"outcome","musicalMap":2,"result":"fired","seq":7,"triggerId":"trg.2"}"#),
        .init("04 seq 11", notReady("trg.3"), 11, "No silent fallback to fixed rate.",
         #"{"kind":"outcome","note":"No silent fallback to fixed rate.","reason":"notReady","result":"dropped","#
            + #""seq":11,"triggerId":"trg.3"}"#),
        .init("05 seq 3", fired("trg.1", 96_000), 3, nil, #"{"assignedFrame":96000,"frame":96000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":3,"triggerId":"trg.1"}"#),
        .init("05 seq 9", staleOutcome("trg.2", .cancelled, .source), 9, nil,
         #"{"kind":"outcome","reason":"source","result":"cancelled","seq":9,"triggerId":"trg.2"}"#),
        .init("05 seq 15", staleOutcome("trg.3", .rejectedStale, .source), 15, nil,
         #"{"kind":"outcome","reason":"source","result":"rejectedStale","seq":15,"triggerId":"trg.3"}"#),
        .init("05 seq 17", fired("trg.4", 288_000), 17, nil, #"{"assignedFrame":288000,"frame":288000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":17,"triggerId":"trg.4"}"#),
        .init("06 seq 5", staleOutcome("trg.1", .cancelled, .cancelScope), 5, nil,
         #"{"kind":"outcome","reason":"cancelScope","result":"cancelled","seq":5,"triggerId":"trg.1"}"#),
        .init("06 seq 6", staleOutcome("trg.2", .cancelled, .cancelScope), 6, nil,
         #"{"kind":"outcome","reason":"cancelScope","result":"cancelled","seq":6,"triggerId":"trg.2"}"#),
        .init("06 seq 9", staleOutcome("trg.3", .rejectedStale, .context), 9, nil,
         #"{"kind":"outcome","reason":"context","result":"rejectedStale","seq":9,"triggerId":"trg.3"}"#),
        .init("06 seq 11", fired("trg.4", 96_000), 11, nil, #"{"assignedFrame":96000,"frame":96000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":11,"triggerId":"trg.4"}"#),
        .init("07 seq 3", notReady("trg.1"), 3, nil,
         #"{"kind":"outcome","reason":"notReady","result":"dropped","seq":3,"triggerId":"trg.1"}"#),
        .init("07 seq 7", fired("trg.2", 96_000), 7, nil, #"{"assignedFrame":96000,"frame":96000,"#
            + #""kind":"outcome","musicalMap":1,"result":"fired","seq":7,"triggerId":"trg.2"}"#),
        .init("07 seq 10", notReady("trg.3"), 10, nil,
         #"{"kind":"outcome","reason":"notReady","result":"dropped","seq":10,"triggerId":"trg.3"}"#),
        // Not an example: a non-dispatch result writes the frames and map revision it holds; `/` stays unescaped.
        .init("held", held, 1, "a/b",
         #"{"assignedFrame":5,"kind":"outcome","musicalMap":1,"note":"a/b","reason":"source","result":"cancelled","#
            + #""seq":1,"triggerId":"trg.1"}"#)
    ]
}

extension ControlContractTests.Triggers {
    @Test func triggerOutcomeV1RecordEncodesTheGoldenOutcomeRecordsExactly() throws {
        for golden in try goldenOutcomeRecords() {
            let record = try TriggerOutcomeV1Record.make(golden.outcome, seq: golden.seq, note: golden.note)
            let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
            #expect(json == golden.json, "\(golden.label)")
            let again = try TriggerOutcomeV1Record.make(golden.outcome, seq: golden.seq, note: golden.note)
            #expect(again == record, "\(golden.label)")
            #expect(try again.encodedJSON() == record.encodedJSON(), "\(golden.label)")
        }
    }

    @Test func triggerOutcomeV1RecordRefusesInOrderWithoutClampingOrRemapping() throws {
        let good = staleOutcome("trg.1", .cancelled, .source)
        var badShape = good
        badShape.frame = 1
        let musicalMap = staleOutcome("trg.1", .rejectedStale, .musicalMap)
        let outsideLoop = TriggerOutcome(trigger: good.trigger, result: .dropped, reason: .outsideLoop)
        let epoch = TriggerOutcome(trigger: good.trigger, result: .rejectedStale, stale: .hostEpoch)
        let joined = TriggerOutcome(trigger: good.trigger, result: .joined, assignedFrame: 10, frame: 12,
                                    startOffsetFrames: 1)
        for shape in [badShape, musicalMap, outsideLoop, epoch, joined] {
            #expect(outcomeRefusal(shape) == .invalidShape(.invalidShape))
        }
        let allBad = TriggerOutcome(trigger: TriggerID(validated: "Trg.1"), result: good.result, stale: good.stale,
                                    frame: 1)
        #expect(outcomeRefusal(allBad, seq: 0, note: "") == .invalidSeq(0))
        #expect(outcomeRefusal(good, seq: -1) == .invalidSeq(-1))
        #expect(outcomeRefusal(allBad, note: "") == .invalidTriggerID(TriggerID(validated: "Trg.1")))
        for raw: StaticString in ["trg_1", "trg", "trg.", "1trg.a", "trg:1.a"] {
            let outcome = TriggerOutcome(trigger: TriggerID(validated: raw), result: good.result, stale: good.stale)
            #expect(outcomeRefusal(outcome) == .invalidTriggerID(outcome.trigger))
        }
        #expect(outcomeRefusal(badShape, note: "") == .invalidShape(.invalidShape))
        #expect(outcomeRefusal(good, note: "") == .invalidNote(bytes: 0))
        #expect(outcomeRefusal(good, note: " \n\t") == .invalidNote(bytes: 3))
        let limit = TriggerOutcomeV1Record.maximumNoteBytes
        #expect(limit == RecordingTakeV1Record.maximumNoteBytes && limit == 256)
        #expect(outcomeRefusal(good, note: String(repeating: "a", count: limit + 1)) == .invalidNote(bytes: 257))
        #expect(outcomeRefusal(good, note: String(repeating: "é", count: 129)) == .invalidNote(bytes: 258))
        #expect(outcomeRefusal(good, note: String(repeating: "a", count: limit)) == nil)
        #expect(outcomeRefusal(good, note: String(repeating: "é", count: 128)) == nil)
        #expect(outcomeRefusal(good, seq: 1, note: nil) == nil)
    }
}
