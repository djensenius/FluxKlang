//
//  ControlContractTests+Media.swift
//  FluxKlangTests
//
//  Trigger scheduling contracts against G-MEDIA v1. Constants follow the
//  media examples: 48 kHz, host timebase 125/3 ns per tick (500 ticks per
//  frame) and 120 BPM (1.5625 frames per tick).
//

import Foundation
import Testing
@testable import FluxKlang

private let primary = ClockID(validated: "smp.main")
private let musicalClock = ClockID(validated: "mus.main")
private let transportKey = GenerationKey(.transport, musicalClock)
private let sourceKey = GenerationKey(.source, StreamID(validated: "str.backing"))
private let contextKey = GenerationKey(.context, GenerationSubject(validated: "context.main"))
private let timebase = HostTimebase(numer: 125, denom: 3)
private let action = ActionID(validated: "act.clip")

private func generations() throws -> GenerationLedger {
    try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000,
                         declaring: [contextKey, sourceKey])
}

private func anchor(frame: Int64, host: UInt64, generation: Generation = .initial, ticks: Int64? = nil,
                    transport: Generation = .initial, iteration: UInt32 = 0) -> ClockAnchor {
    ClockAnchor(
        sample: SampleStamp(clock: primary, generation: generation, frame: frame), host: HostStamp(ticks: host),
        musical: ticks.map {
            MusicalStamp(transport: transport, musicalMap: .initial, ticks: $0, loopIteration: iteration)
        }
    )
}

private func tempoMap(_ segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalMap {
    try MusicalMap(clock: musicalClock, revision: .initial,
                   segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
}

private func musical(_ ledger: GenerationLedger, frame: Int64 = 0, ticks: Int64 = 0,
                     segments: [(Int64, Int64)] = [(0, 500_000)],
                     iteration: UInt32 = 0, host: UInt64 = 0) throws -> MusicalClockMap {
    try MusicalClockMap(anchor: anchor(frame: frame, host: host, ticks: ticks, iteration: iteration),
                        map: tempoMap(segments),
                        nominalRate: 48_000, currentSample: #require(ledger.generation(ledger.primaryClock)),
                        currentTransport: #require(ledger.generation(transportKey)))
}

private func context(
    _ ledger: GenerationLedger, loop: LoopRange? = nil, running: Bool = true
) throws -> MusicalContext {
    let sample = try SampleClockMap(anchor: anchor(frame: 0, host: 0), nominalRate: 48_000, timebase: timebase)
    return MusicalContext(sample: sample, map: try musical(ledger), loop: loop, isRunning: running)
}

private func ready(_ ledger: GenerationLedger) throws -> ActionReadiness {
    var readiness = ActionReadiness()
    try readiness.transition(action, to: .preparing)
    try readiness.markReady(action, preparedAgainst: [GenerationRequirement(key: sourceKey, generation: .initial)],
                            ledger: ledger)
    return readiness
}

private func trigger(_ id: StaticString, _ target: TriggerTarget, _ policy: LatePolicy = .drop,
                     requires: [GenerationKey] = [], arrival: Int64 = 900) -> TriggerStamp {
    var keys = [GenerationKey(.sampleClock, primary), contextKey] + requires
    if target.isMusical, !keys.contains(transportKey) { keys.append(transportKey) }
    return TriggerStamp(
        id: TriggerID(validated: id), action: action, originHost: HostStamp(ticks: 0), horizonFrame: arrival,
        requires: keys.map { GenerationRequirement(key: $0, generation: .initial) }, target: target, latePolicy: policy
    )
}

private func horizon(_ frame: Int64, _ generation: Generation = .initial) -> CommitHorizon {
    CommitHorizon(generation: generation, frame: frame, nominalRate: 48_000)
}

private func outcome(_ decision: CommitDecision) -> TriggerOutcome? {
    if case .resolved(let outcome) = decision { outcome } else { nil }
}

private struct TimingCase {
    let id: StaticString
    let target: TriggerTarget
    let policy: LatePolicy
    let result: OutcomeResult
    let frame: Int64?
    var offset: Int64 = 0
}

extension ControlContractTests {
    struct Triggers {
        @Test func stalePrimaryCannotRaiseNewHorizonButStaleSecondaryMust() throws {
            var ledger = try generations()
            let readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 8)
            let next = try ledger.bump(ledger.primaryClock, reason: .wake)
            _ = try ledger.bump(transportKey, reason: .clockRestart)
            try ledger.recordClockRestart(.init(start: .init(clock: primary, generation: next, frame: 0),
                                                 host: .init(ticks: 0), previousFrame: 999))
            let old = trigger("trg.old", .asap, arrival: 1_000)
            #expect(scheduler.submit(old, ledger: ledger, readiness: readiness) == .accepted)
            let current = GenerationRequirement(key: ledger.primaryClock, generation: next)
            let fresh = TriggerStamp(id: TriggerID(validated: "trg.fresh"), action: action,
                                     originHost: .init(ticks: 0), horizonFrame: 10,
                                     requires: [current, .init(key: contextKey, generation: .initial)],
                                     target: .asap, latePolicy: .drop)
            #expect(scheduler.submit(fresh, ledger: ledger, readiness: readiness) == .accepted)
            let secondarySource = GenerationKey(.source, StreamID(validated: "source.secondary"))
            try ledger.declare(secondarySource)
            try ledger.bump(secondarySource, reason: .sourceLost)
            let secondary = TriggerStamp(
                id: TriggerID(validated: "trg.secondary"), action: action, originHost: .init(ticks: 0),
                horizonFrame: 40, requires: [
                    current, .init(key: contextKey, generation: .initial),
                    .init(key: secondarySource, generation: .initial)
                ],
                target: .asap, latePolicy: .drop
            )
            #expect(scheduler.submit(secondary, ledger: ledger, readiness: readiness) == .accepted)
            #expect(scheduler.outcomes.map(\.result) == [.rejectedStale, .rejectedStale])
            #expect(throws: CommitError.horizonRegressed(floor: 40, found: 30)) {
                try scheduler.commit(fresh.id, at: horizon(30, next), ledger: ledger,
                                     readiness: readiness, musical: nil)
            }
            #expect(outcome(try scheduler.commit(fresh.id, at: horizon(40, next), ledger: ledger,
                                                readiness: readiness, musical: nil))?.frame == 40)
        }

        @Test func retroactiveWindowAndTriggerGridOverrideAreApplied() throws {
            let ledger = try generations()
            let readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 4)
            let base = trigger("trg.retro", .grid(ticks: 960), .joinInProgress(maxLatenessMs: 10), arrival: 100)
            let retro = TriggerStamp(id: base.id, action: action, originHost: .init(ticks: 50_000), horizonFrame: 100,
                                     requires: base.requires, target: base.target, latePolicy: base.latePolicy,
                                     retroactiveMs: 5)
            #expect(try scheduler.submit(retro, ledger: ledger, readiness: readiness, musical: context(ledger))
                == .accepted)
            let joined = outcome(try scheduler.commit(retro.id, at: horizon(200), ledger: ledger,
                                                      readiness: readiness, musical: context(ledger)))
            #expect(joined?.result == .joined && joined?.assignedFrame == 0 && joined?.startOffsetFrames == 200)
            let boundary = trigger("trg.override", .grid(ticks: 960), .nextBoundary(gridTicks: 15_360))
            #expect(try scheduler.submit(boundary, ledger: ledger, readiness: readiness, musical: context(ledger))
                == .accepted)
            let loop = try LoopRange(startTicks: 0, endTicks: 1_000)
            let resolved = outcome(try scheduler.commit(boundary.id, at: horizon(1_000), ledger: ledger,
                readiness: readiness, musical: context(ledger, loop: loop)))
            #expect(resolved?.result == .fired && resolved?.frame == 1_500)
        }

        @Test func capacityRefusesSynchronouslyWithoutAnOutcome() throws {
            let ledger = try generations()
            let readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 2)
            #expect(scheduler.submit(trigger("trg.1", .asap), ledger: ledger, readiness: readiness) == .accepted)
            var stale = trigger("trg.2", .asap, requires: [sourceKey])
            stale = TriggerStamp(id: stale.id, action: action, originHost: stale.originHost, horizonFrame: 900,
                                 requires: [
                                    GenerationRequirement(key: ledger.primaryClock, generation: .initial),
                                    GenerationRequirement(key: contextKey, generation: .initial),
                                    GenerationRequirement(key: sourceKey, generation: try Generation(5))
                                 ],
                                 target: .asap, latePolicy: .drop)
            #expect(scheduler.submit(stale, ledger: ledger, readiness: readiness) == .accepted)
            #expect(scheduler.outcomes.map(\.result) == [.rejectedStale])
            #expect(scheduler.submit(trigger("trg.3", .asap), ledger: ledger, readiness: readiness)
                == .refused(.capacity))
            #expect(scheduler.reservedSlots == 2 && scheduler.pending[TriggerID(validated: "trg.3")] == nil)
            #expect(scheduler.drainOutcomes().count == 1)
            #expect(scheduler.submit(trigger("trg.3", .asap), ledger: ledger, readiness: readiness) == .accepted)
            #expect(scheduler.submit(trigger("trg.1", .asap), ledger: ledger, readiness: readiness)
                == .refused(.duplicateTrigger))
        }

        @Test func latenessIsJudgedAtCommitNotArrival() throws {
            let ledger = try generations()
            let readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 8)
            let cases: [TimingCase] = [
                .init(id: "trg.drop", target: .sample(atFrame: 1_000), policy: .drop, result: .dropped, frame: nil),
                .init(id: "trg.late", target: .sample(atFrame: 1_000), policy: .fireLate(maxLatenessMs: 10),
                      result: .firedLate, frame: 1_100),
                .init(id: "trg.join", target: .sample(atFrame: 1_000), policy: .joinInProgress(maxLatenessMs: 10),
                      result: .joined, frame: 1_100, offset: 100),
                .init(id: "trg.far", target: .sample(atFrame: 1_000), policy: .fireLate(maxLatenessMs: 1),
                      result: .dropped, frame: nil),
                .init(id: "trg.asap", target: .asap, policy: .drop, result: .fired, frame: 1_100),
                .init(id: "trg.ahead", target: .sample(atFrame: 2_000), policy: .drop, result: .fired, frame: 2_000)
            ]
            for item in cases {
                let stamp = trigger(item.id, item.target, item.policy, arrival: 900)
                #expect(scheduler.submit(stamp, ledger: ledger, readiness: readiness) == .accepted)
                let decided = try #require(outcome(try scheduler.commit(
                    stamp.id, at: horizon(1_100), ledger: ledger, readiness: readiness, musical: nil
                )))
                #expect(decided.result == item.result && decided.frame == item.frame)
                #expect(decided.startOffsetFrames == item.offset)
                #expect(decided.frame.map { $0 >= 1_100 } ?? true)
                try decided.validateMediaShape()
            }
        }

        @Test func horizonProgressUsesThePrimaryGenerationOnly() throws {
            var ledger = try generations()
            let readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 8)
            let first = trigger("trg.src", .asap, requires: [sourceKey])
            let second = trigger("trg.b", .asap)
            _ = scheduler.submit(first, ledger: ledger, readiness: readiness)
            _ = scheduler.submit(second, ledger: ledger, readiness: readiness)
            #expect(throws: CommitError.horizonRegressed(floor: 900, found: 800)) {
                try scheduler.commit(second.id, at: horizon(800), ledger: ledger, readiness: readiness, musical: nil)
            }
            try ledger.bump(sourceKey, reason: .sourceLost)
            let cancelled = try scheduler.commit(first.id, at: horizon(1_200), ledger: ledger, readiness: readiness,
                                                 musical: nil)
            #expect(outcome(cancelled)?.result == .cancelled && outcome(cancelled)?.stale == .generation(sourceKey))
            #expect(throws: CommitError.horizonRegressed(floor: 1_200, found: 1_100)) {
                try scheduler.commit(second.id, at: horizon(1_100), ledger: ledger, readiness: readiness, musical: nil)
            }
            let next = try ledger.bump(ledger.primaryClock, reason: .wake)
            #expect(throws: CommitError.staleHorizon) {
                try scheduler.commit(second.id, at: horizon(1_300), ledger: ledger, readiness: readiness, musical: nil)
            }
            let fired = try scheduler.commit(second.id, at: horizon(10, next), ledger: ledger, readiness: readiness,
                                             musical: nil)
            #expect(outcome(fired)?.result == .cancelled)
        }

        @Test func undeclaredDependenciesNeverFireAndDeclaredScopesCancel() throws {
            var ledger = try generations()
            let readiness = try ready(ledger)
            for kind: GenerationKind in [.context, .source, .cancelScope] {
                let unknown = GenerationKey(kind, GenerationSubject(validated: "dependency.unknown"))
                #expect(ledger.generation(unknown) == nil)
                var scheduler = TriggerScheduler(outcomeCapacity: 1)
                let stamp = trigger("trg.unknown", .asap, requires: [unknown])
                #expect(scheduler.submit(stamp, ledger: ledger, readiness: readiness) == .accepted)
                let rejected = try #require(scheduler.outcomes.first)
                #expect(rejected.result == .rejectedStale && rejected.stale == .generation(unknown))
                #expect(scheduler.pending.isEmpty)
                try rejected.validateMediaShape()
            }
            let scope = GenerationKey(.cancelScope, GenerationSubject(validated: "scope.scene"))
            try ledger.declare(scope)
            let stamp = trigger("trg.cancel", .sample(atFrame: 4_000), requires: [scope])
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            #expect(scheduler.submit(stamp, ledger: ledger, readiness: readiness) == .accepted)
            try ledger.bump(scope, reason: .userCancel)
            let cancelled = try #require(outcome(try scheduler.commit(
                stamp.id, at: horizon(1_000), ledger: ledger, readiness: readiness, musical: nil
            )))
            #expect(cancelled.result == .cancelled && cancelled.stale == .generation(scope))
            try cancelled.validateMediaShape()
        }

        @Test func precedenceIsCancelledThenNotReadyWithoutResolvingTheTarget() throws {
            var ledger = try generations()
            var readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 8)
            let both = trigger("trg.both", .musical(atTicks: 0), requires: [transportKey])
            let unready = trigger("trg.unready", .musical(atTicks: 0))
            _ = scheduler.submit(both, ledger: ledger, readiness: readiness)
            _ = scheduler.submit(unready, ledger: ledger, readiness: readiness)
            try readiness.transition(action, to: .invalidated)
            try ledger.bump(transportKey, reason: .locate(ticks: 0))
            let first = try scheduler.commit(both.id, at: horizon(1_000), ledger: ledger, readiness: readiness,
                                             musical: nil)
            #expect(outcome(first)?.result == .cancelled)
            let second = try scheduler.commit(unready.id, at: horizon(1_000), ledger: ledger, readiness: readiness,
                                              musical: nil)
            #expect(outcome(second)?.result == .cancelled)
        }

        @Test func nextBoundaryRequiresTransportAndNamesTheMapRevisionInsideTheLoop() throws {
            var ledger = try generations()
            let readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 8)
            let policy = LatePolicy.nextBoundary(gridTicks: 15_360)
            #expect(scheduler.submit(trigger("trg.bare", .asap, policy), ledger: ledger, readiness: readiness)
                == .refused(.invalid(.nextBoundaryWithoutTransport)))
            let boundary = trigger("trg.nb", .sample(atFrame: 1_000), policy, requires: [transportKey])
            let looped = trigger("trg.loop", .sample(atFrame: 1_000), policy, requires: [transportKey])
            let located = trigger("trg.loc", .asap, policy, requires: [transportKey])
            for stamp in [boundary, looped, located] {
                #expect(scheduler.submit(stamp, ledger: ledger, readiness: readiness) == .accepted)
            }
            let fired = try #require(outcome(try scheduler.commit(
                boundary.id, at: horizon(30_000), ledger: ledger, readiness: readiness, musical: context(ledger)
            )))
            #expect(fired.result == .fired && fired.frame == 48_000 && fired.musicalMap == .initial)
            #expect(fired.assignedFrame == fired.frame)
            try fired.validateMediaShape()
            let loop = try LoopRange(startTicks: 0, endTicks: 23_040)
            let wrapped = try scheduler.commit(looped.id, at: horizon(30_000), ledger: ledger, readiness: readiness,
                                               musical: context(ledger, loop: loop))
            #expect(outcome(wrapped)?.result == .fired && outcome(wrapped)?.frame == 36_000)
            #expect(outcome(wrapped)?.assignedFrame == 36_000)
            try #require(outcome(wrapped)).validateMediaShape()
            try ledger.bump(transportKey, reason: .locate(ticks: 0))
            #expect(scheduler.cancelStale(ledger: ledger).map(\.trigger) == [located.id])
        }

        @Test func stoppedTransportPolicies() throws {
            let ledger = try generations()
            let readiness = try ready(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 8)
            var waiting = trigger("trg.wait", .grid(ticks: 15_360), .nextBoundary(gridTicks: nil))
            var immediate = trigger("trg.now", .grid(ticks: 15_360))
            immediate.stoppedPolicy = .immediate
            var starting = trigger("trg.start", .musical(atTicks: 0))
            starting.stoppedPolicy = .startTransport
            waiting.stoppedPolicy = .wait
            for stamp in [waiting, immediate, starting] {
                #expect(try scheduler.submit(stamp, ledger: ledger, readiness: readiness, musical: context(ledger))
                    == .accepted)
            }
            let stopped = try context(ledger, running: false)
            #expect(try scheduler.commit(waiting.id, at: horizon(1_000), ledger: ledger, readiness: readiness,
                                         musical: stopped) == .waitForTransport)
            #expect(scheduler.pending[waiting.id] != nil)
            let now = try scheduler.commit(immediate.id, at: horizon(1_000), ledger: ledger, readiness: readiness,
                                           musical: stopped)
            #expect(outcome(now)?.frame == 1_000)
            let start = try scheduler.commit(starting.id, at: horizon(1_000), ledger: ledger, readiness: readiness,
                                             musical: stopped)
            #expect(start == .startTransport(TriggerOutcome(trigger: starting.id, result: .fired,
                                                            assignedFrame: 1_000, frame: 1_000)))
            let gridded = try scheduler.commit(waiting.id, at: horizon(1_000), ledger: ledger, readiness: readiness,
                                               musical: context(ledger))
            #expect(outcome(gridded)?.frame == 24_000 && outcome(gridded)?.musicalMap == .initial)
        }

        @Test func triggerShapeValidation() {
            let musicalMap = GenerationKey(.musicalMap, musicalClock)
            #expect(throws: TriggerValidationError.musicalMapDependency) {
                try trigger("trg.m", .asap, requires: [musicalMap]).validate(
                    primaryClock: GenerationKey(.sampleClock, primary), musicalClock: musicalClock
                )
            }
            #expect(throws: TriggerValidationError.duplicateRequirement(sourceKey)) {
                try trigger("trg.d", .asap, requires: [sourceKey, sourceKey]).validate(
                    primaryClock: GenerationKey(.sampleClock, primary), musicalClock: musicalClock
                )
            }
            var retro = trigger("trg.r", .grid(ticks: 3_840), .drop)
            retro.retroactiveMs = 50
            #expect(throws: TriggerValidationError.invalidRetroactive(50)) {
                try retro.validate(primaryClock: GenerationKey(.sampleClock, primary), musicalClock: musicalClock)
            }
            retro = trigger("trg.r", .grid(ticks: 3_840), .fireLate(maxLatenessMs: 40))
            retro.retroactiveMs = 50
            #expect(throws: TriggerValidationError.invalidRetroactive(50)) {
                try retro.validate(primaryClock: GenerationKey(.sampleClock, primary), musicalClock: musicalClock)
            }

        }

        @Test(arguments: [StoppedPolicy.wait, .immediate, .startTransport], [false, true])
        func stoppedAtSubmissionDoesNotAdvanceTheMusicalPosition(
            policy: StoppedPolicy, wrapBeforeCommit: Bool
        ) throws {
            let ledger = try generations()
            let readiness = try ready(ledger)
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let stopped = try context(ledger, loop: loop, running: false)
            let base = trigger("trg.stopped", .grid(ticks: 1_440), arrival: 5_000)
            var stamp = TriggerStamp(
                id: base.id, action: action, originHost: .init(ticks: 2_500_000), horizonFrame: 5_000,
                requires: base.requires, target: base.target, latePolicy: .fireLate(maxLatenessMs: 100)
            )
            stamp.stoppedPolicy = policy
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            try #require(scheduler.submit(stamp, ledger: ledger, readiness: readiness, musical: stopped) == .accepted)
            let decision = try scheduler.commit(stamp.id, at: horizon(5_000), ledger: ledger,
                                                readiness: readiness, musical: stopped)
            let fired = TriggerOutcome(trigger: stamp.id, result: .fired, assignedFrame: 5_000, frame: 5_000)
            switch policy {
            case .immediate: #expect(decision == .resolved(fired))
            case .startTransport: #expect(decision == .startTransport(fired))
            case .wait:
                #expect(decision == .waitForTransport && scheduler.pending[stamp.id] != nil)
                #expect(try scheduler.commit(stamp.id, at: horizon(5_500), ledger: ledger,
                                             readiness: readiness, musical: stopped) == .waitForTransport)
                let currentFrame: Int64 = wrapBeforeCommit ? 9_000 : 6_000
                let resumed = MusicalContext(
                    sample: stopped.sample,
                    map: try musical(ledger, frame: currentFrame, iteration: wrapBeforeCommit ? 1 : 0,
                                     host: UInt64(currentFrame) * 500),
                    loop: loop, resumeAnchor: anchor(frame: 6_000, host: 3_000_000, ticks: 0)
                )
                let commitFrame: Int64 = wrapBeforeCommit ? 9_001 : 6_000
                let result = try #require(outcome(try scheduler.commit(
                    stamp.id, at: horizon(commitFrame), ledger: ledger, readiness: readiness, musical: resumed
                )))
                #expect(result.result == (wrapBeforeCommit ? .firedLate : .fired))
                #expect(result.assignedFrame == 6_000 && result.frame == commitFrame)
                try result.validateMediaShape()
            }
        }

        @Test(arguments: [Int64(0), Int64.min])
        func stoppedOriginRequiresValidResumeProvenanceAfterWrap(sampleAnchorFrame: Int64) throws {
            let ledger = try generations()
            let readiness = try ready(ledger)
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let sample = try SampleClockMap(anchor: anchor(frame: sampleAnchorFrame, host: 0),
                                            nominalRate: 48_000, timebase: timebase)
            let stopped = MusicalContext(sample: sample, map: try musical(ledger, frame: sampleAnchorFrame),
                                         loop: loop, isRunning: false)
            let base = trigger("trg.resume", .grid(ticks: 1_440), arrival: 5_000)
            let stamp = TriggerStamp(
                id: base.id, action: action, originHost: .init(ticks: 2_500_000), horizonFrame: 5_000,
                requires: base.requires, target: base.target, latePolicy: .fireLate(maxLatenessMs: 100)
            )
            let valid = anchor(frame: 6_000, host: 3_000_000, ticks: 0)
            let invalid: [ClockAnchor?] = [
                nil,
                anchor(frame: 6_000, host: 3_000_000, generation: try Generation(2), ticks: 0),
                anchor(frame: 6_000, host: 3_000_000, ticks: 0, transport: try Generation(2)),
                anchor(frame: 6_000, host: 3_000_000, ticks: 0, iteration: 1),
                anchor(frame: 6_000, host: 3_000_000, ticks: 960),
                anchor(frame: 0, host: 0, ticks: 0),
                anchor(frame: 0, host: 3_000_000, ticks: 0),
                anchor(frame: 5_945, host: 3_000_000, ticks: 0),
                anchor(frame: 6_055, host: 3_000_000, ticks: 0),
                anchor(frame: 5_946, host: 3_000_250, ticks: 0),
                anchor(frame: 6_055, host: 3_000_250, ticks: 0),
                anchor(frame: 10_000, host: 5_000_000, ticks: 0),
                anchor(frame: 6_000, host: 3_000_000),
                ClockAnchor(sample: SampleStamp(clock: ClockID(validated: "smp.other"), generation: .initial,
                                                frame: 6_000), host: valid.host, musical: valid.musical)
            ]
            // At 6000 predicted frames the exact budget is 54, not a rounded or enlarged budget.
            // Half-frame predictions must retain their fractional error until the tolerance comparison.
            let tolerated: [ClockAnchor?] = [
                valid,
                anchor(frame: 5_946, host: 3_000_000, ticks: 0),
                anchor(frame: 6_054, host: 3_000_000, ticks: 0),
                anchor(frame: 6_001, host: 3_000_250, ticks: 0),
                anchor(frame: 5_947, host: 3_000_250, ticks: 0),
                anchor(frame: 6_054, host: 3_000_250, ticks: 0)
            ]
            for provenance in invalid + tolerated {
                var scheduler = TriggerScheduler(outcomeCapacity: 1)
                try #require(scheduler.submit(
                    stamp, ledger: ledger, readiness: readiness, musical: stopped
                ) == .accepted)
                let running = MusicalContext(
                    sample: stopped.sample,
                    map: try musical(ledger, frame: 9_000, iteration: 1, host: 4_500_000),
                    loop: loop, resumeAnchor: provenance
                )
                let result = try #require(outcome(try scheduler.commit(
                    stamp.id, at: horizon(9_001), ledger: ledger, readiness: readiness, musical: running
                )))
                // With a minimum-frame sample anchor, even frame 6000 has an error of 2^63 frames.
                if sampleAnchorFrame == 0 && tolerated.contains(provenance) {
                    #expect(result.result == .firedLate && result.frame == 9_001)
                    #expect(result.assignedFrame == provenance?.sample.frame)
                    try result.validateMediaShape()
                } else {
                    #expect(result.result == .dropped && result.reason == .invalidTiming)
                    #expect(result.assignedFrame == nil && result.frame == nil)
                }
            }
        }
    }
}
