import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct SchedulingValidation {
        private let sample = ClockID(validated: "clock.sample")
        private let musical = ClockID(validated: "clock.musical")
        private let action = ActionID(validated: "action.test")
        private let contextKey = GenerationKey(.context, GenerationSubject(validated: "context.test"))

        private func generations() throws -> GenerationLedger {
            try GenerationLedger(primaryClock: sample, musicalClock: musical, nominalRate: 48_000,
                                 declaring: [contextKey])
        }

        private func readiness(_ ledger: GenerationLedger) throws -> ActionReadiness {
            var readiness = ActionReadiness()
            try readiness.transition(action, to: .preparing)
            try readiness.markReady(action, preparedAgainst: [], ledger: ledger)
            return readiness
        }

        private func stamp(target: TriggerTarget, grid: Int64 = 960, origin: UInt64 = 0,
                           iteration: UInt32 = 0, policy: LatePolicy? = nil) -> TriggerStamp {
            TriggerStamp(
                id: TriggerID(validated: "trigger.test"), action: action, originHost: .init(ticks: origin),
                horizonFrame: 0, requires: [
                    .init(key: GenerationKey(.sampleClock, sample), generation: .initial),
                    .init(key: contextKey, generation: .initial),
                    .init(key: GenerationKey(.transport, musical), generation: .initial)
                ], target: target, latePolicy: policy ?? .nextBoundary(gridTicks: grid), loopIteration: iteration
            )
        }

        private func context(loop: LoopRange? = nil, frame: Int64 = 0, ticks: Int64 = 0,
                             iteration: UInt32 = 0, rate: Int = 48_000,
                             segments: [(Int64, Int64)] = [(0, 500_000)], host: UInt64? = nil,
                             revision: Generation = .initial) throws -> MusicalContext {
            let anchor = ClockAnchor(
                sample: .init(clock: sample, generation: .initial, frame: frame),
                host: .init(ticks: host ?? UInt64(frame) * 500),
                musical: .init(transport: .initial, musicalMap: .initial, ticks: ticks, loopIteration: iteration)
            )
            let map = try MusicalMap(clock: musical, revision: revision,
                                     segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
            return try MusicalContext(
                sample: SampleClockMap(anchor: anchor, nominalRate: rate, timebase: .init(numer: 125, denom: 3)),
                map: MusicalClockMap(anchor: anchor, map: map, nominalRate: rate,
                                     currentSample: .initial, currentTransport: .initial),
                loop: loop
            )
        }

        private func resolve(_ stamp: TriggerStamp, frame: Int64, context: MusicalContext?) throws -> TriggerOutcome {
            let ledger = try generations()
            let readiness = try readiness(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            let origin: MusicalContext? = if case .grid = stamp.target { context } else { nil }
            #expect(scheduler.submit(stamp, ledger: ledger, readiness: readiness, musical: origin) == .accepted)
            let decision = try scheduler.commit(
                stamp.id, at: .init(generation: .initial, frame: frame, nominalRate: 48_000),
                ledger: ledger, readiness: readiness, musical: context
            )
            guard case .resolved(let outcome) = decision else {
                throw ControlValidationError.invalid("Expected terminal outcome")
            }
            #expect(scheduler.pending.isEmpty && scheduler.outcomes == [outcome])
            #expect(throws: CommitError.unknownTrigger(stamp.id)) {
                try scheduler.commit(stamp.id, at: .init(generation: .initial, frame: frame, nominalRate: 48_000),
                                     ledger: ledger, readiness: readiness, musical: context)
            }
            return outcome
        }

        @Test func foreignMusicalCountersAreRejectedBeforeAdmissionAndCannotRaiseTheHorizon() throws {
            var ledger = try generations()
            let readiness = try readiness(ledger)
            var scheduler = TriggerScheduler(outcomeCapacity: 2)
            let foreign = GenerationKey(.transport, ClockID(validated: "clock.foreign"))
            let invalid = TriggerStamp(
                id: TriggerID(validated: "trigger.foreign"), action: action, originHost: .init(ticks: 0),
                horizonFrame: 999, requires: [
                    .init(key: ledger.primaryClock, generation: .initial),
                    .init(key: contextKey, generation: .initial),
                    .init(key: foreign, generation: .initial)
                ], target: .asap, latePolicy: .nextBoundary(gridTicks: 960)
            )
            let counters = ledger.current
            #expect(throws: GenerationLedgerError.undeclaredMusicalClock(foreign)) {
                try ledger.bump(foreign, reason: .locate(ticks: 0))
            }
            #expect(ledger.current == counters)
            #expect(scheduler.submit(invalid, ledger: ledger, readiness: readiness)
                == .refused(.invalid(.undeclaredClock(foreign))))
            #expect(scheduler.reservedSlots == 0 && scheduler.outcomes.isEmpty)
            let valid = stamp(target: .asap)
            #expect(scheduler.submit(valid, ledger: ledger, readiness: readiness) == .accepted)
            let decision = try scheduler.commit(
                valid.id, at: .init(generation: .initial, frame: 10, nominalRate: 48_000),
                ledger: ledger, readiness: readiness, musical: context()
            )
            guard case .resolved(let outcome) = decision else { Issue.record("Expected terminal outcome"); return }
            #expect(outcome.result == .fired && outcome.frame == 10)
        }

        @Test func everyNextBoundaryFallbackChecksLoopBoundsAndAcceptsTheEnd() throws {
            let loop = try LoopRange(startTicks: 960, endTicks: 1_920)
            // Each initial musical target is inside the loop; only the fallback exceeds its end.
            let targets: [TriggerTarget] = [.sample(atFrame: 1_500), .musical(atTicks: 960), .grid(ticks: 960)]
            for target in targets {
                let trigger = stamp(target: target, origin: 750_000)
                let wrapped = try resolve(trigger, frame: 3_001, context: context(loop: loop))
                #expect(wrapped.result == .fired && wrapped.frame == 4_500)
                #expect(wrapped.assignedFrame == 4_500 && wrapped.musicalMap == .initial)
                let end = try resolve(trigger, frame: 2_000, context: context(loop: loop))
                #expect(end.result == .fired && end.frame == 3_000 && end.musicalMap == .initial)
            }
            // A sample target can fall back before the loop start, or exactly onto it.
            let before = try resolve(stamp(target: .sample(atFrame: -1)), frame: 0, context: context(loop: loop))
            #expect(before.result == .dropped && before.reason == .outsideLoop)
            let start = try resolve(stamp(target: .sample(atFrame: -1)), frame: 1, context: context(loop: loop))
            #expect(start.result == .fired && start.frame == 1_500)
            // ASAP is never late, so nextBoundary must not turn it into a musical fallback.
            let asap = try resolve(stamp(target: .asap), frame: 4_000, context: context(loop: loop))
            #expect(asap.result == .fired && asap.frame == 4_000 && asap.musicalMap == nil)
        }

        @Test func fallbackCrossesWrapWithoutAnAlreadyAnchoredNextPass() throws {
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let trigger = stamp(target: .sample(atFrame: 1_000), grid: 1_440)
            for frame: Int64 in [2_500, 3_000, 6_000, 3_000_000_000] {
                let result = try resolve(trigger, frame: frame, context: context(loop: loop))
                let expected = frame == 2_500 ? 3_000 : frame
                #expect(result.result == .fired && result.frame == expected)
                #expect(result.assignedFrame == expected && result.musicalMap == .initial)
            }
            let empty = try LoopRange(startTicks: 100, endTicks: 200)
            let rejected = try resolve(trigger, frame: 2_500, context: context(loop: empty))
            #expect(rejected.result == .dropped && rejected.reason == .outsideLoop && rejected.frame == nil)
        }

        @Test func initialGridCrossesWrapWithoutUsingTheLateFallback() throws {
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let trigger = stamp(target: .grid(ticks: 1_440), origin: 1_250_000, policy: .drop)
            let initial = try resolve(trigger, frame: 2_500, context: context(loop: loop))
            #expect(initial.result == .fired && initial.assignedFrame == 3_000 && initial.frame == 3_000)
            let late = try resolve(trigger, frame: 3_001, context: context(loop: loop))
            #expect(late.result == .dropped && late.reason == .late && late.assignedFrame == 3_000)
            let empty = try LoopRange(startTicks: 100, endTicks: 200)
            let outside = try resolve(stamp(target: .grid(ticks: 1_440), origin: 100_000, policy: .drop),
                                      frame: 200, context: context(loop: empty))
            #expect(outside.result == .dropped && outside.reason == .outsideLoop)
        }

        @Test func currentPassFallbackDoesNotNarrowAnUnrepresentableWrap() throws {
            let frame = Int64.max - 2_000
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let current = try context(loop: loop, frame: frame, host: 0)
            #expect(throws: ClockMapError.overflow) { try current.map.frame(atTicks: loop.endTicks) }
            let result = try resolve(stamp(target: .sample(atFrame: frame), grid: 960),
                                     frame: frame + 1, context: current)
            #expect(result.result == .fired && result.assignedFrame == Int64.max - 500)
            #expect(result.frame == Int64.max - 500 && result.musicalMap == .initial)
        }

        @Test(arguments: [false, true])
        func pendingGridRetainsItsOccurrenceAcrossTempoEditsAndWraps(wrapped: Bool) throws {
            var ledger = try generations()
            let readiness = try readiness(ledger)
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let trigger = stamp(target: .grid(ticks: 1_440), origin: 1_250_000, policy: .drop)
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            #expect(scheduler.submit(trigger, ledger: ledger, readiness: readiness)
                == .refused(.musicalContextRequired))
            #expect(scheduler.pending.isEmpty && scheduler.outcomes.isEmpty)
            #expect(try scheduler.submit(trigger, ledger: ledger, readiness: readiness, musical: context(loop: loop))
                == .accepted)
            let revision = try ledger.bump(GenerationKey(.musicalMap, musical), reason: .tempoEdit)
            #expect(scheduler.cancelStale(ledger: ledger).isEmpty)
            let current = try context(loop: loop, frame: wrapped ? 3_000 : 0, iteration: wrapped ? 1 : 0,
                                      segments: [(0, 1_000_000)], revision: revision)
            let decision = try scheduler.commit(
                trigger.id, at: .init(generation: .initial, frame: wrapped ? 3_001 : 2_500, nominalRate: 48_000),
                ledger: ledger, readiness: readiness, musical: current
            )
            guard case .resolved(let outcome) = decision else { Issue.record("Expected terminal outcome"); return }
            #expect(outcome.musicalMap == revision)
            if wrapped {
                #expect(outcome.result == .dropped && outcome.reason == .late && outcome.assignedFrame == 3_000)
            } else {
                // Re-quantizing the same host origin on the new tempo would incorrectly choose tick 1440/frame 4500.
                #expect(outcome.result == .fired && outcome.assignedFrame == 6_000 && outcome.frame == 6_000)
            }
        }

        @Test func gridBeforeWrapKeepsItsOriginPassWhenDeliveredAfterWrap() throws {
            let ledger = try generations()
            let readiness = try readiness(ledger)
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let trigger = stamp(target: .grid(ticks: 960), origin: 500_000, policy: .drop)
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            #expect(try scheduler.submit(trigger, ledger: ledger, readiness: readiness, musical: context(loop: loop))
                == .accepted)
            let decision = try scheduler.commit(
                trigger.id, at: .init(generation: .initial, frame: 3_001, nominalRate: 48_000),
                ledger: ledger, readiness: readiness, musical: context(loop: loop, frame: 3_000, iteration: 1)
            )
            guard case .resolved(let outcome) = decision else { Issue.record("Expected terminal outcome"); return }
            #expect(outcome.result == .dropped && outcome.reason == .late && outcome.assignedFrame == 1_500)
        }

        @Test func virtualFallbackPassesKeepFractionalLengthAndTempoSegments() throws {
            let fractional = try context(loop: LoopRange(startTicks: 0, endTicks: 3))
            let trigger = stamp(target: .sample(atFrame: 0), grid: 2)
            // First wrap rounds 4.6875 to 5; later virtual passes retain the exact 4.6875 length.
            for (horizon, expected): (Int64, Int64) in [(5, 5), (10, 13), (15, 18)] {
                let result = try resolve(trigger, frame: horizon, context: fractional)
                #expect(result.result == .fired && result.frame == expected && result.assignedFrame == expected)
            }
            let segmented = try context(loop: LoopRange(startTicks: 0, endTicks: 1_920),
                                        segments: [(0, 500_000), (960, 1_000_000)])
            for (horizon, expected): (Int64, Int64) in [(4_000, 4_500), (5_000, 7_500)] {
                let result = try resolve(stamp(target: .sample(atFrame: 0), grid: 1_440),
                                         frame: horizon, context: segmented)
                #expect(result.result == .fired && result.frame == expected && result.assignedFrame == expected)
            }
        }

        @Test func sampleAndASAPIgnoreUnneededMusicalContextAcrossWrap() throws {
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let wrapped = try context(loop: loop, frame: 3_000, ticks: 0, iteration: 1)
            for target: TriggerTarget in [.sample(atFrame: 4_000), .asap] {
                for policy: LatePolicy in [.drop, .nextBoundary(gridTicks: 960)] {
                    let base = stamp(target: target)
                    let requires = policy == .drop
                        ? base.requires.filter { $0.key.kind != .transport } : base.requires
                    let trigger = TriggerStamp(
                        id: base.id, action: action, originHost: base.originHost, horizonFrame: 0,
                        requires: requires, target: target, latePolicy: policy
                    )
                    let withContext = try resolve(trigger, frame: 3_001, context: wrapped)
                    let withoutContext = try resolve(trigger, frame: 3_001, context: nil)
                    #expect(withContext == withoutContext)
                    #expect(withContext.result == .fired && withContext.musicalMap == nil)
                    #expect(withContext.frame == (target == .asap ? 3_001 : 4_000))
                }
            }
            let fallback = try resolve(stamp(target: .sample(atFrame: 1_000)), frame: 3_001, context: wrapped)
            #expect(fallback.result == .fired && fallback.frame == 4_500)
            let badRate = try resolve(stamp(target: .sample(atFrame: 1_000)), frame: 3_001,
                                      context: context(rate: 96_000))
            #expect(badRate.result == .dropped && badRate.reason == .invalidTiming)
        }

        @Test func fullRangeSampleLatenessKeepsItsPolicy() throws {
            let base = stamp(target: .sample(atFrame: .min))
            let fallback = try resolve(base, frame: 0, context: context())
            #expect(fallback.result == .fired && fallback.assignedFrame == 0 && fallback.frame == 0)
            for policy: LatePolicy in [.drop, .fireLate(maxLatenessMs: 1_000),
                                       .joinInProgress(maxLatenessMs: 1_000)] {
                let trigger = TriggerStamp(
                    id: base.id, action: action, originHost: base.originHost, horizonFrame: 0,
                    requires: base.requires, target: base.target, latePolicy: policy
                )
                for frame: Int64 in [0, .max] {
                    let result = try resolve(trigger, frame: frame, context: nil)
                    #expect(result.result == .dropped && result.reason == .late)
                    #expect(result.assignedFrame == .min && result.frame == nil && result.startOffsetFrames == 0)
                }
            }
            let ahead = try resolve(stamp(target: .sample(atFrame: .max)), frame: .max, context: nil)
            #expect(ahead.result == .fired && ahead.assignedFrame == .max && ahead.frame == .max)
        }

        @Test func sampleAndASAPStillRequireCurrentContext() throws {
            for target: TriggerTarget in [.sample(atFrame: 4_000), .asap] {
                var ledger = try generations()
                let readiness = try readiness(ledger)
                let base = stamp(target: target)
                let missing = TriggerStamp(
                    id: base.id, action: action, originHost: base.originHost, horizonFrame: 0,
                    requires: [.init(key: ledger.primaryClock, generation: .initial)],
                    target: target, latePolicy: .drop
                )
                var scheduler = TriggerScheduler(outcomeCapacity: 1)
                #expect(scheduler.submit(missing, ledger: ledger, readiness: readiness)
                    == .refused(.invalid(.missingContext)))
                let valid = TriggerStamp(
                    id: base.id, action: action, originHost: base.originHost, horizonFrame: 0,
                    requires: base.requires.filter { $0.key.kind != .transport },
                    target: target, latePolicy: .drop
                )
                #expect(scheduler.submit(valid, ledger: ledger, readiness: readiness) == .accepted)
                try ledger.bump(contextKey, reason: .contextChange)
                let decision = try scheduler.commit(
                    valid.id, at: .init(generation: .initial, frame: 3_001, nominalRate: 48_000),
                    ledger: ledger, readiness: readiness, musical: context(frame: 3_000, iteration: 1)
                )
                guard case .resolved(let outcome) = decision else {
                    Issue.record("Expected context cancellation"); return
                }
                #expect(outcome.result == .cancelled && outcome.stale == .generation(contextKey))
                var staleScheduler = TriggerScheduler(outcomeCapacity: 1)
                #expect(staleScheduler.submit(valid, ledger: ledger, readiness: readiness) == .accepted)
                #expect(staleScheduler.outcomes.first?.result == .rejectedStale)
                #expect(staleScheduler.outcomes.first?.stale == .generation(contextKey))
            }
        }

        @Test func wrappedTargetsKeepTheirOccurrenceAndUseTheNextPassAnchor() throws {
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            let wrapped = try context(loop: loop, frame: 3_000, ticks: 0, iteration: 1)
            for target: TriggerTarget in [.sample(atFrame: 3_000), .musical(atTicks: 0), .grid(ticks: 960)] {
                let outcome = try resolve(stamp(target: target, origin: 1_500_000, iteration: 1),
                                          frame: 3_001, context: wrapped)
                #expect(outcome.result == .fired && outcome.frame == 4_500 && outcome.musicalMap == .initial)
            }
            let oldPass = try resolve(stamp(target: .musical(atTicks: 0)), frame: 3_001, context: wrapped)
            #expect(oldPass.result == .dropped && oldPass.reason == .invalidTiming)
            let loopEnd = try resolve(stamp(target: .musical(atTicks: 1_920)),
                                     frame: 3_000, context: context(loop: loop))
            #expect(loopEnd.result == .fired && loopEnd.frame == 3_000)
        }

        @Test func commitRejectsInconsistentRatesWithoutConsumingThePendingTrigger() throws {
            var ledger = try generations()
            let generation = try ledger.bump(ledger.primaryClock, reason: .rateChange(nominalRate: 96_000))
            try ledger.bump(GenerationKey(.transport, musical), reason: .clockRestart)
            try ledger.recordClockRestart(.init(start: .init(clock: sample, generation: generation, frame: 0),
                                                 host: .init(ticks: 0), previousFrame: 999))
            let readiness = try readiness(ledger)
            let trigger = TriggerStamp(
                id: TriggerID(validated: "trigger.rate"), action: action, originHost: .init(ticks: 0),
                horizonFrame: 0, requires: [
                    .init(key: ledger.primaryClock, generation: generation),
                    .init(key: contextKey, generation: .initial)
                ],
                target: .asap, latePolicy: .drop
            )
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            #expect(scheduler.submit(trigger, ledger: ledger, readiness: readiness) == .accepted)
            #expect(throws: CommitError.invalidRate) {
                try scheduler.commit(trigger.id, at: .init(generation: generation, frame: 999, nominalRate: 48_000),
                                     ledger: ledger, readiness: readiness, musical: nil)
            }
            #expect(scheduler.pending[trigger.id] != nil && scheduler.outcomes.isEmpty)
            let decision = try scheduler.commit(
                trigger.id, at: .init(generation: generation, frame: 10, nominalRate: 96_000),
                ledger: ledger, readiness: readiness, musical: nil
            )
            guard case .resolved(let outcome) = decision else { Issue.record("Expected terminal outcome"); return }
            #expect(outcome.result == .fired && outcome.frame == 10)
            let mismatch = try resolve(stamp(target: .musical(atTicks: 960)),
                                       frame: 100, context: context(rate: 96_000))
            #expect(mismatch.result == .dropped && mismatch.reason == .invalidTiming)
        }

        @Test func pendingMusicalTargetsUseTheCurrentMapWithoutCancellation() throws {
            var ledger = try generations()
            let readiness = try readiness(ledger)
            let trigger = stamp(target: .musical(atTicks: 15_360))
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            #expect(scheduler.submit(trigger, ledger: ledger, readiness: readiness) == .accepted)
            let revision = try ledger.bump(GenerationKey(.musicalMap, musical), reason: .tempoEdit)
            #expect(scheduler.cancelStale(ledger: ledger).isEmpty)
            let anchor = ClockAnchor(
                sample: .init(clock: sample, generation: .initial, frame: 0), host: .init(ticks: 0),
                musical: .init(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 0)
            )
            let map = try MusicalMap(clock: musical, revision: revision,
                                     segments: [TempoSegment(atTicks: 0, microsPerQuarter: 1_000_000)])
            let context = try MusicalContext(
                sample: SampleClockMap(anchor: anchor, nominalRate: 48_000, timebase: .init(numer: 1, denom: 1)),
                map: MusicalClockMap(anchor: anchor, map: map, nominalRate: 48_000,
                                     currentSample: .initial, currentTransport: .initial)
            )
            let result = try scheduler.commit(
                trigger.id, at: .init(generation: .initial, frame: 100, nominalRate: 48_000),
                ledger: ledger, readiness: readiness, musical: context
            )
            guard case .resolved(let outcome) = result else { Issue.record("Expected terminal outcome"); return }
            #expect(outcome.result == .fired && outcome.frame == 48_000 && outcome.musicalMap == revision)
        }
    }
}

extension ControlContractTests.SchedulingValidation {
    @Test func frozenNextPassTargetSurvivesAnotherWrap() throws {
        let ledger = try generations()
        let readiness = try readiness(ledger)
        let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
        let trigger = stamp(target: .grid(ticks: 1_440), origin: 1_250_000, policy: .fireLate(maxLatenessMs: 100))
        var scheduler = TriggerScheduler(outcomeCapacity: 1)
        #expect(try scheduler.submit(trigger, ledger: ledger, readiness: readiness, musical: context(loop: loop))
            == .accepted)
        let decision = try scheduler.commit(
            trigger.id, at: .init(generation: .initial, frame: 6_001, nominalRate: 48_000),
            ledger: ledger, readiness: readiness, musical: context(loop: loop, frame: 6_000, iteration: 2)
        )
        guard case .resolved(let result) = decision else { Issue.record("Expected terminal outcome"); return }
        #expect(result.result == .firedLate && result.assignedFrame == 3_000 && result.frame == 6_001)
        try result.validateMediaShape()
    }

    @Test func mismatchedMusicalPassIsRefusedBeforeExtrapolation() throws {
        let ledger = try generations()
        let readiness = try readiness(ledger)
        let trigger = stamp(target: .musical(atTicks: 0), iteration: .max, policy: .drop)
        // Frozen B accepts both ranges. Probe the dangerous product without executing trapping arithmetic.
        let length = Int128(Int64.max) * 500_000 * 48_000
        #expect(length.multipliedReportingOverflow(by: Int128(UInt32.max) - 1).overflow)
        for end: Int64 in [1_920, .max] {
            let current = try context(loop: LoopRange(startTicks: 0, endTicks: end))
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            #expect(scheduler.submit(trigger, ledger: ledger, readiness: readiness, musical: current)
                == .refused(.invalidMusicalContext))
            #expect(scheduler.pending.isEmpty && scheduler.outcomes.isEmpty)
        }
    }

    @Test func missingOriginContextCannotInventAFutureMusicalPass() throws {
        for end: Int64 in [1_920, .max] {
            let result = try resolve(stamp(target: .musical(atTicks: 0), iteration: .max, policy: .drop),
                                     frame: 1, context: context(loop: LoopRange(startTicks: 0, endTicks: end)))
            #expect(result.result == .dropped && result.reason == .invalidTiming)
        }
    }

    @Test func matchingMaximumPassIsValidButARegressedContextIsNot() throws {
        let ledger = try generations()
        let readiness = try readiness(ledger)
        let loop = try LoopRange(startTicks: 0, endTicks: .max)
        let origin = try context(loop: loop, iteration: .max)
        let trigger = stamp(target: .musical(atTicks: 0), iteration: .max, policy: .drop)
        for iteration: UInt32 in [.max, 0] {
            var scheduler = TriggerScheduler(outcomeCapacity: 1)
            #expect(scheduler.submit(trigger, ledger: ledger, readiness: readiness, musical: origin) == .accepted)
            let decision = try scheduler.commit(
                trigger.id, at: .init(generation: .initial, frame: 0, nominalRate: 48_000),
                ledger: ledger, readiness: readiness, musical: context(loop: loop, iteration: iteration)
            )
            guard case .resolved(let result) = decision else { Issue.record("Expected terminal outcome"); return }
            if iteration == .max {
                #expect(result.result == .fired && result.assignedFrame == 0 && result.frame == 0)
                try result.validateMediaShape()
            } else {
                #expect(result.result == .dropped && result.reason == .invalidTiming)
            }
        }
    }
}
