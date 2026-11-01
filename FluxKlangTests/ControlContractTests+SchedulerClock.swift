import Testing
@testable import FluxKlang

private let schedulerPrimary = ClockID(validated: "smp.scheduler")
private let schedulerMusical = ClockID(validated: "mus.scheduler")
private let schedulerTimebase = HostTimebase(numer: 125, denom: 3)
private let schedulerRates = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

private enum RestartOrder: CaseIterable, Sendable {
    case recordFirst, transportFirst, noTransport
}

private func schedulerLedger(rate: Int = 48_000, musical: Bool = true) throws -> GenerationLedger {
    try GenerationLedger(primaryClock: schedulerPrimary, musicalClock: musical ? schedulerMusical : nil,
                         nominalRate: rate)
}

private func schedulerAnchor(_ frame: Int64, host: UInt64, generation: Generation = .initial) -> ClockAnchor {
    ClockAnchor(sample: .init(clock: schedulerPrimary, generation: generation, frame: frame), host: .init(ticks: host))
}

private func schedulerMap(_ anchor: ClockAnchor, rate: Int = 48_000) throws -> SampleClockMap {
    try SampleClockMap(anchor: anchor, nominalRate: rate, timebase: schedulerTimebase)
}

private func expectClockFailure<Failure: Error & Equatable>(
    _ error: Failure, clock: inout SchedulerClock, operation: (inout SchedulerClock) throws -> Void
) {
    let before = clock
    #expect(throws: error) { try operation(&clock) }
    #expect(clock == before)
}

extension ControlContractTests {
    struct SchedulerClocks {
        @Test(arguments: schedulerRates, [Int64(0), 1, 10])
        func firstAndRestartCandidatesUseActualAgreementAcrossSpans(rate: Int, seconds: Int64) throws {
            for restart in [false, true] {
                var ledger = try schedulerLedger(rate: rate, musical: false)
                let generation = restart ? try ledger.bump(ledger.primaryClock, reason: .wake) : Generation.initial
                let origin = schedulerAnchor(700, host: 1_000, generation: generation)
                if restart {
                    try ledger.recordClockRestart(.init(start: origin.sample, host: origin.host, previousFrame: .max))
                }
                let baseline = try schedulerMap(origin, rate: rate)
                var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
                if !restart {
                    try clock.observe(origin, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
                }
                let host = origin.host.ticks + UInt64(seconds) * 24_000_000
                let center = try baseline.frame(atHost: .init(ticks: host), current: generation)
                // Constructs boundary inputs only; B's actual predicate is the acceptance oracle.
                let tolerance = Int64(rate) * (seconds + 1) / 1_000
                for offset in [-tolerance - 1, -tolerance, 0, tolerance, tolerance + 1] {
                    let candidate = schedulerAnchor(center + offset, host: host, generation: generation)
                    let accepted = baseline.agrees(candidate)
                    if restart {
                        #expect(ledger.acceptsFirstAnchor(candidate, nominalRate: rate,
                                                         timebase: schedulerTimebase) == accepted)
                    }
                    var staged = clock
                    if accepted {
                        try staged.observe(candidate, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
                        #expect(try staged.snapshot(ledger: ledger).baseline == baseline)
                        #expect(try staged.requireReady(ledger: ledger).anchor == candidate)
                    } else {
                        expectClockFailure(SchedulerClockError.invalidAnchor, clock: &staged) {
                            try $0.observe(candidate, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
                        }
                    }
                    #expect(try clock.snapshot(ledger: ledger).latestAnchor == (restart ? nil : origin))
                }
            }
        }

        @Test(arguments: schedulerRates)
        func genuineNonzeroFirstBaselineRejectsRollingDrift(rate: Int) throws {
            let ledger = try schedulerLedger(rate: rate)
            let first = schedulerAnchor(123_456, host: 1_000_000)
            let step = Int64(rate + rate / 500)
            let valid = schedulerAnchor(first.sample.frame + step, host: first.host.ticks + 24_000_000)
            let drifting = schedulerAnchor(first.sample.frame + 2 * step, host: first.host.ticks + 48_000_000)
            let baseline = try schedulerMap(first, rate: rate)
            #expect(baseline.agrees(valid))
            #expect(try schedulerMap(valid, rate: rate).agrees(drifting))
            #expect(!baseline.agrees(drifting))
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            for anchor in [first, valid] {
                try clock.observe(anchor, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
            }
            expectClockFailure(SchedulerClockError.invalidAnchor, clock: &clock) {
                try $0.observe(drifting, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
            }
            let current = try clock.snapshot(ledger: ledger)
            #expect(current.baseline == baseline && current.latestAnchor == valid && current.horizon == valid.sample)
        }

        @Test(arguments: [false, true])
        func observationsConstrainCommitsAndMustNotRegressLatest(hostRegression: Bool) throws {
            let ledger = try schedulerLedger()
            let first = schedulerAnchor(5_000, host: 1_000)
            let latest = schedulerAnchor(53_000, host: 24_001_000)
            let regressing = schedulerAnchor(hostRegression ? 53_000 : 52_999,
                                             host: hostRegression ? 24_000_999 : 24_001_000)
            #expect(try schedulerMap(first).agrees(regressing))
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            for anchor in [first, latest] {
                try clock.observe(anchor, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            }
            expectClockFailure(SchedulerClockError.invalidAnchor, clock: &clock) {
                try $0.observe(regressing, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            }
            expectClockFailure(SchedulerClockError.regressingHorizon, clock: &clock) {
                try $0.advanceHorizon(schedulerAnchor(52_999, host: 0).sample, nominalRate: 48_000, ledger: ledger)
            }
            let future = schedulerAnchor(54_000, host: 0).sample
            try clock.advanceHorizon(future, nominalRate: 48_000, ledger: ledger)
            try clock.observe(latest, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            #expect(try clock.snapshot(ledger: ledger).horizon == future)
            #expect(try clock.requireReady(ledger: ledger).anchor == latest)
        }

        @Test(arguments: schedulerRates, RestartOrder.allCases)
        fileprivate func restartUsesRecordBaselineAndPreservesEarlyFloor(rate: Int, order: RestartOrder) throws {
            var ledger = try schedulerLedger(musical: order != .noTransport)
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            let old = schedulerAnchor(90_000, host: 0)
            try clock.observe(old, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            try clock.recordArrival(schedulerAnchor(.max, host: 0).sample, ledger: ledger)
            let generation = try ledger.bump(ledger.primaryClock, reason: .rateChange(nominalRate: rate))
            let origin = schedulerAnchor(700, host: 1_000, generation: generation)
            let record = ClockRestartRecord(start: origin.sample, host: origin.host, previousFrame: 90_000)
            let step = Int64(rate + rate / 500)
            let valid = schedulerAnchor(700 + step, host: 24_001_000, generation: generation)
            let invalid = schedulerAnchor(valid.sample.frame + 1, host: valid.host.ticks, generation: generation)
            let floor = schedulerAnchor(700 + 4 * Int64(rate), host: 0, generation: generation).sample
            #expect(try clock.snapshot(ledger: ledger).horizon == nil)
            #expect(throws: SchedulerClockError.restartIncomplete) { try clock.requireReady(ledger: ledger) }
            try clock.recordArrival(floor, ledger: ledger)
            try clock.recordArrival(origin.sample, ledger: ledger)
            try clock.advanceHorizon(floor, nominalRate: rate, ledger: ledger)
            expectClockFailure(ClockMapError.staleSampleGeneration, clock: &clock) {
                try $0.recordArrival(schedulerAnchor(.max, host: 0).sample, ledger: ledger)
            }
            expectClockFailure(SchedulerClockError.regressingHorizon, clock: &clock) {
                try $0.advanceHorizon(origin.sample, nominalRate: rate, ledger: ledger)
            }
            expectClockFailure(SchedulerClockError.restartIncomplete, clock: &clock) {
                try $0.observe(valid, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
            }
            let transport = GenerationKey(.transport, schedulerMusical)
            if order == .transportFirst {
                try ledger.bump(transport, reason: .clockRestart)
            } else {
                try ledger.recordClockRestart(record)
            }
            if order != .noTransport {
                #expect(ledger.hasRestartObligations)
                expectClockFailure(SchedulerClockError.restartIncomplete, clock: &clock) {
                    try $0.observe(valid, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
                }
                if order == .transportFirst {
                    try ledger.recordClockRestart(record)
                } else {
                    try ledger.bump(transport, reason: .clockRestart)
                }
            }
            #expect(!ledger.hasRestartObligations)
            let baseline = try schedulerMap(origin, rate: rate)
            #expect(baseline.agrees(valid) && !baseline.agrees(invalid))
            #expect(ledger.acceptsFirstAnchor(valid, nominalRate: rate, timebase: schedulerTimebase))
            #expect(!ledger.acceptsFirstAnchor(invalid, nominalRate: rate, timebase: schedulerTimebase))
            expectClockFailure(SchedulerClockError.invalidAnchor, clock: &clock) {
                try $0.observe(invalid, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
            }
            for earlier in [schedulerAnchor(699, host: 1_000, generation: generation),
                            schedulerAnchor(700, host: 999, generation: generation)] {
                #expect(!baseline.agrees(earlier))
                expectClockFailure(SchedulerClockError.invalidAnchor, clock: &clock) {
                    try $0.observe(earlier, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
                }
            }
            let unready = try clock.snapshot(ledger: ledger)
            #expect(unready.generation == generation && unready.nominalRate == rate && unready.horizon == floor)
            #expect(unready.baseline == nil && unready.latestAnchor == nil)
            #expect(throws: SchedulerClockError.notReady) { try clock.requireReady(ledger: ledger) }
            try clock.advanceHorizon(floor, nominalRate: rate, ledger: ledger)
            try clock.observe(valid, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
            let ready = try clock.snapshot(ledger: ledger)
            #expect(ready.baseline == baseline && ready.latestAnchor == valid && ready.horizon == floor)
            #expect(try clock.requireReady(ledger: ledger) == schedulerMap(valid, rate: rate))
            let drifting = schedulerAnchor(700 + 2 * step, host: 48_001_000, generation: generation)
            #expect(try schedulerMap(valid, rate: rate).agrees(drifting))
            #expect(!baseline.agrees(drifting))
            expectClockFailure(SchedulerClockError.invalidAnchor, clock: &clock) {
                try $0.observe(drifting, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
            }
        }

        @Test func failedFirstCandidateWithoutFloorDoesNotPublishAndSkippedGenerationCanReanchor() throws {
            var ledger = try schedulerLedger(musical: false)
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            try clock.observe(schedulerAnchor(90_000, host: 0), nominalRate: 48_000,
                              timebase: schedulerTimebase, ledger: ledger)
            for frame: Int64 in [0, -700] {
                let generation = try ledger.bump(ledger.primaryClock, reason: .wake)
                let origin = schedulerAnchor(frame, host: 1_000, generation: generation)
                try ledger.recordClockRestart(.init(start: origin.sample, host: origin.host, previousFrame: 90_000))
            }
            let record = try #require(ledger.restartRecord)
            let valid = ClockAnchor(sample: record.start, host: record.host)
            let invalid = schedulerAnchor(-701, host: 1_000, generation: record.start.generation)
            #expect(!ledger.acceptsFirstAnchor(invalid, nominalRate: 48_000, timebase: schedulerTimebase))
            expectClockFailure(SchedulerClockError.invalidAnchor, clock: &clock) {
                try $0.observe(invalid, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            }
            let unready = try clock.snapshot(ledger: ledger)
            #expect(unready.baseline == nil && unready.latestAnchor == nil && unready.horizon == nil)
            try clock.observe(valid, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            #expect(try clock.snapshot(ledger: ledger).horizon == valid.sample)
            #expect(try clock.requireReady(ledger: ledger).anchor == valid)
        }

        @Test(arguments: [-1, 0, 44_099, 44_100, 48_001, 192_001, Int.max], [false, true])
        func rateMustBeExactlyDeclaredEvenBeforeFirstAnchor(rate: Int, anchored: Bool) throws {
            let ledger = try schedulerLedger()
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            let anchor = schedulerAnchor(10, host: 100)
            if anchored {
                try clock.observe(anchor, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            }
            expectClockFailure(ClockMapError.invalidRate(rate), clock: &clock) {
                try $0.observe(anchor, nominalRate: rate, timebase: schedulerTimebase, ledger: ledger)
            }
            expectClockFailure(ClockMapError.invalidRate(rate), clock: &clock) {
                try $0.advanceHorizon(anchor.sample, nominalRate: rate, ledger: ledger)
            }
            if !anchored {
                try clock.advanceHorizon(anchor.sample, nominalRate: 48_000, ledger: ledger)
                #expect(throws: SchedulerClockError.notReady) { try clock.requireReady(ledger: ledger) }
            }
        }

        @Test func stampsCannotSubstituteClockOrNoncurrentGeneration() throws {
            let ledger = try schedulerLedger()
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            let first = schedulerAnchor(100, host: 1_000)
            try clock.observe(first, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            let foreign = SampleStamp(clock: schedulerMusical, generation: .initial, frame: .max)
            expectClockFailure(SchedulerClockError.primaryClockMismatch, clock: &clock) {
                try $0.recordArrival(foreign, ledger: ledger)
            }
            expectClockFailure(SchedulerClockError.primaryClockMismatch, clock: &clock) {
                try $0.advanceHorizon(foreign, nominalRate: 48_000, ledger: ledger)
            }
            expectClockFailure(SchedulerClockError.primaryClockMismatch, clock: &clock) {
                try $0.observe(.init(sample: foreign, host: .init(ticks: .max)),
                               nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            }
            for generation in [try Generation.initial.next(), try Generation(Generation.maximumValue)] {
                let wrong = schedulerAnchor(.max, host: .max, generation: generation)
                expectClockFailure(ClockMapError.staleSampleGeneration, clock: &clock) {
                    try $0.recordArrival(wrong.sample, ledger: ledger)
                }
                expectClockFailure(ClockMapError.staleSampleGeneration, clock: &clock) {
                    try $0.advanceHorizon(wrong.sample, nominalRate: 48_000, ledger: ledger)
                }
                expectClockFailure(ClockMapError.staleSampleGeneration, clock: &clock) {
                    try $0.observe(wrong, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
                }
            }
        }

        @Test func ledgerCannotChangePrimaryDeclarationOrSameGenerationRate() throws {
            let ledger = try schedulerLedger()
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            let anchor = schedulerAnchor(100, host: 1_000)
            try clock.observe(anchor, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            let foreign = try GenerationLedger(primaryClock: schedulerMusical, musicalClock: nil, nominalRate: 48_000)
            for (changed, error) in [(foreign, SchedulerClockError.primaryClockMismatch),
                                     (try schedulerLedger(rate: 96_000), .declarationChanged)] {
                #expect(throws: error) { try clock.snapshot(ledger: changed) }
                #expect(throws: error) { try clock.requireReady(ledger: changed) }
                expectClockFailure(error, clock: &clock) { try $0.recordArrival(anchor.sample, ledger: changed) }
                expectClockFailure(error, clock: &clock) {
                    try $0.advanceHorizon(anchor.sample, nominalRate: changed.nominalRate, ledger: changed)
                }
                expectClockFailure(error, clock: &clock) {
                    try $0.observe(anchor, nominalRate: changed.nominalRate,
                                   timebase: schedulerTimebase, ledger: changed)
                }
            }
        }

        @Test(arguments: [HostTimebase(numer: 0, denom: 1), .init(numer: 1, denom: 0),
                          .init(numer: 0, denom: 0), .init(numer: 250, denom: 6), .init(numer: 1, denom: 1)])
        func timebaseIsExplicitNonzeroAndProcessWide(timebase: HostTimebase) throws {
            var ledger = try schedulerLedger(musical: false)
            let malformed = timebase.numer == 0 || timebase.denom == 0
            if malformed {
                #expect(throws: ClockMapError.invalidTimebase) {
                    try SchedulerClock(ledger: ledger, timebase: timebase)
                }
            }
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            let first = schedulerAnchor(100, host: 1_000)
            try clock.observe(first, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            for restart in [false, true] {
                let generation = restart ? try ledger.bump(ledger.primaryClock, reason: .wake) : Generation.initial
                let candidate = schedulerAnchor(100, host: 1_000, generation: generation)
                if restart {
                    try ledger.recordClockRestart(.init(start: candidate.sample,
                                                        host: candidate.host, previousFrame: 99))
                }
                if malformed {
                    expectClockFailure(ClockMapError.invalidTimebase, clock: &clock) {
                        try $0.observe(candidate, nominalRate: 48_000, timebase: timebase, ledger: ledger)
                    }
                } else {
                    expectClockFailure(SchedulerClockError.declarationChanged, clock: &clock) {
                        try $0.observe(candidate, nominalRate: 48_000, timebase: timebase, ledger: ledger)
                    }
                }
            }
        }

        @Test func musicalPayloadAndTransportMapChangesDoNotOwnPhysicalState() throws {
            var ledger = try schedulerLedger()
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            let physical = schedulerAnchor(500, host: 1_000)
            var poisoned = physical
            poisoned.musical = .init(transport: try Generation(Generation.maximumValue),
                                     musicalMap: try Generation(Generation.maximumValue),
                                     ticks: .min, loopIteration: .max)
            try clock.observe(poisoned, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            let floor = schedulerAnchor(200_000, host: 0).sample
            try clock.recordArrival(floor, ledger: ledger)
            let before = try clock.snapshot(ledger: ledger)
            try ledger.bump(.init(.transport, schedulerMusical), reason: .locate(ticks: 0))
            try ledger.bump(.init(.musicalMap, schedulerMusical), reason: .tempoEdit)
            try ledger.bump(.init(.transport, schedulerMusical), reason: .transportRestart)
            #expect(try clock.snapshot(ledger: ledger) == before)
            #expect(try clock.requireReady(ledger: ledger).anchor == physical)
            let later = schedulerAnchor(48_500, host: 24_001_000)
            poisoned = later
            poisoned.musical = .init(transport: .initial, musicalMap: .initial, ticks: -1, loopIteration: .max)
            try clock.observe(poisoned, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            let current = try clock.snapshot(ledger: ledger)
            #expect(try current.baseline == schedulerMap(physical) && current.latestAnchor == later)
            #expect(current.horizon == floor)
        }

        @Test(arguments: [HostTimebase(numer: 125, denom: 3), .init(numer: .max, denom: .max)])
        func fullWidthHostSpanAndNegativeFrameOriginRemainExact(timebase: HostTimebase) throws {
            let ledger = try schedulerLedger(rate: 192_000)
            let first = schedulerAnchor(.min, host: 0)
            let map = try SampleClockMap(anchor: first, nominalRate: 192_000, timebase: timebase)
            let frame = try map.frame(atHost: .init(ticks: .max), current: .initial)
            let last = schedulerAnchor(frame, host: .max)
            #expect(map.agrees(last))
            var clock = try SchedulerClock(ledger: ledger, timebase: timebase)
            try clock.observe(first, nominalRate: 192_000, timebase: timebase, ledger: ledger)
            try clock.observe(last, nominalRate: 192_000, timebase: timebase, ledger: ledger)
            try clock.advanceHorizon(schedulerAnchor(.max, host: 0).sample, nominalRate: 192_000, ledger: ledger)
            try clock.recordArrival(first.sample, ledger: ledger)
            #expect(try clock.snapshot(ledger: ledger).horizon?.frame == .max)
            #expect(try clock.requireReady(ledger: ledger).anchor == last)
            let enormous = HostTimebase(numer: .max, denom: 1)
            let wideMap = try SampleClockMap(anchor: first, nominalRate: 192_000, timebase: enormous)
            let extreme = schedulerAnchor(.max, host: .max)
            #expect(!wideMap.agrees(extreme))
            var other = try SchedulerClock(ledger: ledger, timebase: enormous)
            try other.observe(first, nominalRate: 192_000, timebase: enormous, ledger: ledger)
            expectClockFailure(SchedulerClockError.invalidAnchor, clock: &other) {
                try $0.observe(extreme, nominalRate: 192_000, timebase: enormous, ledger: ledger)
            }
        }

        @Test(arguments: [false, true])
        func maximumFrameAndHostAreLegalFirstAndRestartOrigins(restart: Bool) throws {
            var ledger = try schedulerLedger(musical: false)
            let generation = restart ? try ledger.bump(ledger.primaryClock, reason: .wake) : Generation.initial
            let first = schedulerAnchor(.max, host: .max, generation: generation)
            if restart {
                try ledger.recordClockRestart(.init(start: first.sample, host: first.host, previousFrame: .min))
            }
            var clock = try SchedulerClock(ledger: ledger, timebase: schedulerTimebase)
            try clock.advanceHorizon(first.sample, nominalRate: 48_000, ledger: ledger)
            #expect(throws: SchedulerClockError.notReady) { try clock.requireReady(ledger: ledger) }
            try clock.observe(first, nominalRate: 48_000, timebase: schedulerTimebase, ledger: ledger)
            #expect(try clock.requireReady(ledger: ledger).anchor == first)
            expectClockFailure(SchedulerClockError.regressingHorizon, clock: &clock) {
                try $0.advanceHorizon(schedulerAnchor(.min, host: 0, generation: generation).sample,
                                      nominalRate: 48_000, ledger: ledger)
            }
        }
    }
}
