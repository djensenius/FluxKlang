//
//  ControlContractTests+Transport.swift
//  FluxKlangTests
//
//  Clock maps, generation obligations, readiness and capture delivery without
//  command admission or scheduling. Uses the G-MEDIA 48 kHz, 120 BPM examples.
//

import Foundation
import Testing
@testable import FluxKlang

private let primary = ClockID(validated: "smp.main")
private let musicalClock = ClockID(validated: "mus.main")
private let transportKey = GenerationKey(.transport, musicalClock)
private let sourceKey = GenerationKey(.source, StreamID(validated: "str.backing"))
private let timebase = HostTimebase(numer: 125, denom: 3)
private let action = ActionID(validated: "act.clip")

private func anchor(frame: Int64, host: UInt64, generation: Generation = .initial, ticks: Int64? = nil,
                    transport: Generation = .initial) -> ClockAnchor {
    ClockAnchor(
        sample: SampleStamp(clock: primary, generation: generation, frame: frame), host: HostStamp(ticks: host),
        musical: ticks.map { MusicalStamp(transport: transport, musicalMap: .initial, ticks: $0, loopIteration: 0) }
    )
}

private func tempoMap(_ segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalMap {
    try MusicalMap(clock: musicalClock, revision: .initial,
                   segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
}

private func musical(_ ledger: GenerationLedger, frame: Int64 = 0, ticks: Int64 = 0,
                     segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalClockMap {
    try MusicalClockMap(anchor: anchor(frame: frame, host: 0, ticks: ticks), map: tempoMap(segments),
                        nominalRate: 48_000, currentSample: #require(ledger.generation(ledger.primaryClock)),
                        currentTransport: #require(ledger.generation(transportKey)))
}

private func ready(_ ledger: GenerationLedger) throws -> ActionReadiness {
    var readiness = ActionReadiness()
    try readiness.transition(action, to: .preparing)
    try readiness.markReady(action, preparedAgainst: [GenerationRequirement(key: sourceKey, generation: .initial)],
                            ledger: ledger)
    return readiness
}

extension ControlContractTests {
    struct ClockMaps {
        @Test func hostTicksMapToFramesExactlyWithHalfUpRounding() throws {
            let map = try SampleClockMap(anchor: anchor(frame: 1_000, host: 1_000_000), nominalRate: 48_000,
                                         timebase: timebase)
            let expectations: [(UInt64, Int64)] = [(1_000_500, 1_001), (1_000_250, 1_001), (1_000_249, 1_000),
                                                   (999_750, 1_000), (999_749, 999)]
            for (host, frame) in expectations {
                #expect(try map.frame(atHost: HostStamp(ticks: host), current: .initial) == frame)
            }
            #expect(throws: ClockMapError.staleSampleGeneration) {
                try map.frame(atHost: HostStamp(ticks: 0), current: Generation.initial.next())
            }
        }

        @Test func anchorsAgreeWithinOneMillisecondPlusPointOnePercent() throws {
            let map = try SampleClockMap(anchor: anchor(frame: 0, host: 0), nominalRate: 48_000, timebase: timebase)
            #expect(map.agrees(anchor(frame: 48_096, host: 24_000_000)))
            #expect(map.agrees(anchor(frame: 47_904, host: 24_000_000)))
            #expect(!map.agrees(anchor(frame: 48_097, host: 24_000_000)))
            #expect(!map.agrees(anchor(frame: 48_000, host: 24_000_000, generation: try Generation.initial.next())))
        }

        @Test func musicalTicksAndFramesInvertAcrossTempoSegments() throws {
            let ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            let map = try musical(ledger, segments: [(0, 500_000), (15_360, 1_000_000)])
            #expect(try map.frame(atTicks: 15_360) == 24_000)
            #expect(try map.frame(atTicks: 30_720) == 72_000)
            #expect(try map.ticks(atFrame: 72_000) == 30_720)
            #expect(try map.ticks(atFrame: 48_000) == 23_040)
            #expect(try map.boundary(atOrAfterFrame: 24_000, grid: 15_360) == 15_360)
            #expect(try map.boundary(atOrAfterFrame: 24_001, grid: 15_360) == 30_720)
            let late = try musical(ledger, frame: 72_000, ticks: 30_720, segments: [(0, 500_000), (15_360, 1_000_000)])
            #expect(try late.ticks(atFrame: 12_000) == 7_680)
            #expect(try late.ticks(atFrame: 0) == 0)
            #expect(try late.frame(atTicks: 7_680) == 12_000)
        }

        @Test func mapsLoopsAndStaleTransportsAreRejected() throws {
            #expect(throws: ClockMapError.invalidMap) { try tempoMap([(10, 500_000)]) }
            #expect(throws: ClockMapError.invalidMap) { try tempoMap([(0, 500_000), (0, 400_000)]) }
            #expect(throws: ClockMapError.invalidLoop(startTicks: 10, endTicks: 10)) {
                try LoopRange(startTicks: 10, endTicks: 10)
            }
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            try ledger.bump(transportKey, reason: .locate(ticks: 0))
            #expect(throws: ClockMapError.staleTransport) { try musical(ledger) }
        }

        @Test func idsMustBeUnique() throws {
            #expect(throws: DuplicateIDError(rawValue: "smp.main")) {
                try ContractUniqueness.require([primary, primary])
            }
            try ContractUniqueness.require([TakeID(validated: "tk.1"), TakeID(validated: "tk.2")])
        }
    }
}

extension ControlContractTests {
    struct Generations {
        @Test func eachPrimaryClockChangeNeedsItsOwnRestartRecordAndTransportBump() throws {
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            let second = try ledger.bump(ledger.primaryClock, reason: .rateChange(nominalRate: 96_000))
            #expect(throws: GenerationLedgerError.restartObligationsPending) {
                try ledger.bump(ledger.primaryClock, reason: .wake)
            }
            let other = GenerationKey(.transport, ClockID(validated: "mus.other"))
            #expect(throws: GenerationLedgerError.undeclaredMusicalClock(other)) {
                try ledger.bump(other, reason: .clockRestart)
            }
            let foreignMap = GenerationKey(.musicalMap, ClockID(validated: "mus.other"))
            #expect(throws: GenerationLedgerError.undeclaredMusicalClock(foreignMap)) {
                try ledger.bump(foreignMap, reason: .tempoEdit)
            }
            #expect(ledger.awaitingTransportBump)
            try ledger.bump(transportKey, reason: .clockRestart)
            #expect(ledger.hasRestartObligations)
            #expect(throws: GenerationLedgerError.noPendingRestart) {
                try ledger.bump(transportKey, reason: .clockRestart)
            }
            try ledger.recordClockRestart(ClockRestartRecord(
                start: SampleStamp(clock: primary, generation: second, frame: 0), host: HostStamp(ticks: 1_000),
                previousFrame: 47_999
            ))
            #expect(!ledger.hasRestartObligations)
            #expect(ledger.resume == .afterRestart(previousFrame: 47_999))
            try ledger.bump(ledger.primaryClock, reason: .deviceRestart)
        }

        @Test func firstAnchorAfterRestartIsNotEarlierAndWithinTolerance() throws {
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: nil, nominalRate: 48_000)
            let second = try ledger.bump(ledger.primaryClock, reason: .rateChange(nominalRate: 96_000))
            #expect(!ledger.acceptsFirstAnchor(anchor(frame: 0, host: 1_000, generation: second),
                                               nominalRate: 96_000, timebase: timebase))
            try ledger.recordClockRestart(ClockRestartRecord(
                start: SampleStamp(clock: primary, generation: second, frame: 0), host: HostStamp(ticks: 1_000),
                previousFrame: 1_234
            ))
            #expect(!ledger.hasRestartObligations && ledger.resume == nil)
            #expect(!ledger.acceptsFirstAnchor(anchor(frame: 0, host: 1_000, generation: second),
                                               nominalRate: 48_000, timebase: timebase))
            let oneSecond: UInt64 = 1_000 + 250 * 96_000
            for (frame, host, accepted) in [(Int64(96_192), oneSecond, true), (96_193, oneSecond, false),
                                            (-1, 1_000, false), (0, 999, false), (0, 1_000, true)] {
                #expect(ledger.acceptsFirstAnchor(anchor(frame: frame, host: host, generation: second),
                                                  nominalRate: 96_000, timebase: timebase) == accepted)
            }
        }

        @Test func locateSupersedesAPendingRestartResumePosition() throws {
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            let second = try ledger.bump(ledger.primaryClock, reason: .configurationChange)
            try ledger.bump(transportKey, reason: .clockRestart)
            try ledger.bump(transportKey, reason: .locate(ticks: 61_440))
            try ledger.recordClockRestart(ClockRestartRecord(
                start: SampleStamp(clock: primary, generation: second, frame: 0), host: HostStamp(ticks: 0),
                previousFrame: 500
            ))
            #expect(ledger.resume == .locate(ticks: 61_440))
            #expect(throws: GenerationLedgerError.restartAlreadyRecorded) {
                try ledger.recordClockRestart(ClockRestartRecord(
                    start: SampleStamp(clock: primary, generation: second, frame: 0), host: HostStamp(ticks: 0),
                    previousFrame: 500
                ))
            }
        }

        @Test(arguments: [false, true])
        func transportRestartSupersedesClockResumeInEitherRecordOrder(recordFirst: Bool) throws {
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            let second = try ledger.bump(ledger.primaryClock, reason: .wake)
            let record = ClockRestartRecord(
                start: SampleStamp(clock: primary, generation: second, frame: 0), host: HostStamp(ticks: 1_000),
                previousFrame: 500
            )
            if recordFirst {
                try ledger.recordClockRestart(record)
                #expect(ledger.resume == .afterRestart(previousFrame: 500))
            }
            try ledger.bump(transportKey, reason: .transportRestart)
            #expect(ledger.resume == nil)
            #expect(ledger.awaitingTransportBump)
            if !recordFirst { try ledger.recordClockRestart(record) }
            #expect(ledger.resume == nil)
            #expect(ledger.hasRestartObligations)
            try ledger.bump(transportKey, reason: .clockRestart)
            #expect(!ledger.hasRestartObligations && ledger.resume == nil)

            let third = try ledger.bump(ledger.primaryClock, reason: .deviceRestart)
            try ledger.recordClockRestart(.init(
                start: .init(clock: primary, generation: third, frame: 0),
                host: .init(ticks: 2_000), previousFrame: 900
            ))
            #expect(ledger.resume == .afterRestart(previousFrame: 900))
        }

        @Test(arguments: [-1, Int64.min])
        func negativeLocatePreservesCountersResumeAndPendingRestart(ticks: Int64) throws {
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            try ledger.bump(transportKey, reason: .locate(ticks: .max))
            let second = try ledger.bump(ledger.primaryClock, reason: .wake)
            let counters = ledger.current
            let resume = ledger.resume
            #expect(throws: GenerationLedgerError.invalidLocateTicks(ticks)) {
                try ledger.bump(transportKey, reason: .locate(ticks: ticks))
            }
            #expect(ledger.current == counters && ledger.resume == resume)
            #expect(ledger.restartRecord == nil && ledger.awaitingTransportBump)
            try ledger.recordClockRestart(.init(
                start: .init(clock: primary, generation: second, frame: 0),
                host: .init(ticks: 1_000), previousFrame: 500
            ))
            #expect(ledger.resume == .afterRestart(previousFrame: 500))
            try ledger.bump(transportKey, reason: .clockRestart)
            try ledger.bump(transportKey, reason: .locate(ticks: 0))
            #expect(!ledger.hasRestartObligations && ledger.resume == .locate(ticks: 0))
        }

        @Test func sourceBumpInvalidatesReadinessUntilRePrepared() throws {
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            try ledger.declare(sourceKey)
            var readiness = try ready(ledger)
            let lost = try ledger.bump(sourceKey, reason: .sourceLost)
            #expect(readiness.generationChanged(sourceKey) == [action])
            #expect(readiness.reasons[action] == .sourceChanged)
            let reacquired = try ledger.bump(sourceKey, reason: .sourceReacquired)
            readiness.generationChanged(sourceKey)
            #expect(readiness.state(action) == .invalidated)
            try readiness.transition(action, to: .preparing)
            #expect(readiness.reasons[action] == nil)
            #expect(throws: ReadinessError.stalePreparation(action)) {
                try readiness.markReady(action, preparedAgainst: [.init(key: sourceKey, generation: lost)],
                                        ledger: ledger)
            }
            try readiness.markReady(action, preparedAgainst: [.init(key: sourceKey, generation: reacquired)],
                                    ledger: ledger)
            #expect(readiness.state(action) == .ready)
            #expect(throws: ReadinessError.illegalTransition(action, from: .ready, to: .preparing)) {
                try readiness.transition(action, to: .preparing)
            }
        }

        @Test func capturesStampedBeforeARestartOrLocateAreUnsupported() throws {
            var ledger = try GenerationLedger(primaryClock: primary, musicalClock: musicalClock, nominalRate: 48_000)
            let stamp = SampleStamp(clock: primary, generation: .initial, frame: 10)
            #expect(ledger.classifyCapture(sample: stamp, transport: .initial) == .current)
            try ledger.bump(transportKey, reason: .locate(ticks: 0))
            let afterLocate = ledger.classifyCapture(sample: stamp, transport: .initial)
            #expect(afterLocate == .stampedBeforeTransportChange)
            try ledger.bump(ledger.primaryClock, reason: .wake)
            let afterRestart = ledger.classifyCapture(sample: stamp, transport: nil)
            #expect(afterRestart == .stampedBeforeClockRestart)
            for delivery in [afterLocate, afterRestart] {
                #expect(!delivery.isSupported && !delivery.mayRemap && !delivery.mayClaimLossless)
            }
        }

        @Test func firstRestartInheritsDeclaredRateUntilExplicitRateChange() throws {
            for reason: GenerationBumpReason in [.wake, .deviceRestart, .configurationChange] {
                var ledger = try GenerationLedger(primaryClock: primary, musicalClock: nil, nominalRate: 44_100)
                for (bump, rate) in [(reason, 44_100), (.rateChange(nominalRate: 96_000), 96_000), (.wake, 96_000)] {
                    let generation = try ledger.bump(ledger.primaryClock, reason: bump)
                    try ledger.recordClockRestart(.init(
                        start: .init(clock: primary, generation: generation, frame: 0),
                        host: .init(ticks: 0), previousFrame: 100
                    ))
                    let first = anchor(frame: 0, host: 0, generation: generation)
                    #expect(ledger.nominalRate == rate)
                    #expect(ledger.acceptsFirstAnchor(first, nominalRate: rate, timebase: timebase))
                    #expect(!ledger.acceptsFirstAnchor(first, nominalRate: 48_000, timebase: timebase))
                }
            }
        }

        @Test func captureCannotInventATransport() throws {
            let ledger = try GenerationLedger(primaryClock: primary, musicalClock: nil, nominalRate: 48_000)
            let stamp = SampleStamp(clock: primary, generation: .initial, frame: 0)
            #expect(ledger.classifyCapture(sample: stamp, transport: nil) == .current)
            let delivery = ledger.classifyCapture(sample: stamp, transport: .initial)
            #expect(delivery == .undeclaredTransport)
            #expect(!delivery.isSupported && !delivery.mayRemap && !delivery.mayClaimLossless)
        }
    }
}
