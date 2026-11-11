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

private typealias GenerationRefusal = GenerationV1RecordRefusal

private func generationRefusal(_ counter: GenerationKey, _ reason: GenerationBumpReason, _ from: Int = 1,
                               _ to: Int = 2, map: MusicalMap? = nil, meter: MusicalMeter? = nil,
                               seq: Int = 1, note: String? = nil) throws -> GenerationRefusal? {
    let (from, to) = try (Generation(from), Generation(to))
    do {
        _ = try GenerationV1Record.make(counter: counter, from: from, to: to, reason: reason,
                                        musicalMap: map, meter: meter, seq: seq, note: note)
        return nil
    } catch {
        return error
    }
}

/// A golden `generationRecord` from a media contract example (`<example> seq <n>`), keys sorted, compact;
/// the table pins all 11 example generation records.
private struct GoldenGeneration {
    let label: String
    let counter: GenerationKey
    let from: Int
    let reason: GenerationBumpReason
    let seq: Int
    let json: String
}

private func goldenGenerationRecords() -> [GoldenGeneration] {
    let sample = GenerationKey(.sampleClock, primary), map = GenerationKey(.musicalMap, musicalClock)
    let source = GenerationKey(.source, GenerationSubject(validated: "src.backing"))
    let scope = GenerationKey(.cancelScope, GenerationSubject(validated: "set.verse"))
    let context = GenerationKey(.context, GenerationSubject(validated: "ctx.main"))
    func golden(_ label: String, _ counter: GenerationKey, _ reason: GenerationBumpReason, _ seq: Int,
                from: Int = 1, _ json: String) -> GoldenGeneration {
        GoldenGeneration(label: label, counter: counter, from: from, reason: reason, seq: seq, json: json)
    }
    return [
        golden("01 seq 4", sample, .rateChange(nominalRate: 96_000), 4, #"{"counter":"sampleClock/smp.main","#
               + #""from":1,"kind":"generation","nominalRate":96000,"reason":"rateChange","seq":4,"to":2}"#),
        golden("01 seq 6", transportKey, .clockRestart, 6, #"{"counter":"transport/mus.main","from":1,"#
               + #""kind":"generation","reason":"clockRestart","seq":6,"to":2}"#),
        golden("03 seq 12", transportKey, .locate(ticks: 61_440), 12, #"{"counter":"transport/mus.main","#
               + #""from":1,"kind":"generation","reason":"locate","seq":12,"to":2}"#),
        golden("04 seq 5", map, .tempoEdit, 5, #"{"counter":"musicalMap/mus.main","from":1,"kind":"generation","#
               + #""meter":{"denominator":4,"numerator":3},"musicalMap":[{"atTicks":0,"microsPerQuarter":500000},"#
               + #"{"atTicks":122880,"microsPerQuarter":400000}],"reason":"tempoEdit","seq":5,"to":2}"#),
        golden("05 seq 6", source, .sourceLost, 6, #"{"counter":"source/src.backing","from":1,"#
               + #""kind":"generation","reason":"sourceLost","seq":6,"to":2}"#),
        golden("05 seq 10", source, .sourceReacquired, 10, from: 2, #"{"counter":"source/src.backing","from":2,"#
               + #""kind":"generation","reason":"sourceReacquired","seq":10,"to":3}"#),
        golden("06 seq 4", scope, .userCancel, 4, #"{"counter":"cancelScope/set.verse","from":1,"#
               + #""kind":"generation","reason":"userCancel","seq":4,"to":2}"#),
        golden("06 seq 7", context, .contextChange, 7, #"{"counter":"context/ctx.main","from":1,"#
               + #""kind":"generation","reason":"contextChange","seq":7,"to":2}"#),
        golden("08 seq 3", sample, .rateChange(nominalRate: 96_000), 3, #"{"counter":"sampleClock/smp.main","#
               + #""from":1,"kind":"generation","nominalRate":96000,"reason":"rateChange","seq":3,"to":2}"#),
        golden("09 seq 7", sample, .deviceRestart, 7, #"{"counter":"sampleClock/smp.main","from":1,"#
               + #""kind":"generation","reason":"deviceRestart","seq":7,"to":2}"#),
        golden("09 seq 9", transportKey, .clockRestart, 9, #"{"counter":"transport/mus.main","from":1,"#
               + #""kind":"generation","reason":"clockRestart","seq":9,"to":2}"#)
    ]
}

extension ControlContractTests.Generations {
    @Test func generationV1RecordEncodesTheGoldenGenerationRecordsExactly() throws {
        let revised = try MusicalMap(clock: musicalClock, revision: Generation(2), segments: [
            TempoSegment(atTicks: 0, microsPerQuarter: 500_000),
            TempoSegment(atTicks: 122_880, microsPerQuarter: 400_000)
        ])
        let threeFour = try MusicalMeter(MeterFields(numerator: 3, denominator: 4))
        for golden in goldenGenerationRecords() {
            let isMap = golden.counter.kind == .musicalMap
            func build() throws -> GenerationV1Record {
                try GenerationV1Record.make(counter: golden.counter, from: Generation(golden.from),
                                            to: Generation(golden.from + 1), reason: golden.reason,
                                            musicalMap: isMap ? revised : nil, meter: isMap ? threeFour : nil,
                                            seq: golden.seq)
            }
            let record = try build()
            let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
            #expect(json == golden.json, "\(golden.label)")
            let again = try build()
            #expect(again == record, "\(golden.label)")
            #expect(try again.encodedJSON() == record.encodedJSON(), "\(golden.label)")
        }
        // Not an example: an inherited meter is omitted, and a note keeps `/` unescaped.
        let inherited = try GenerationV1Record.make(
            counter: GenerationKey(.musicalMap, musicalClock), from: .initial, to: Generation(2),
            reason: .externalTempo, musicalMap: revised, seq: 1, note: "a/b")
        #expect(try String(data: inherited.encodedJSON(), encoding: .utf8) == #"{"counter":"musicalMap/mus.main","#
                + #""from":1,"kind":"generation","musicalMap":[{"atTicks":0,"microsPerQuarter":500000},"#
                + #"{"atTicks":122880,"microsPerQuarter":400000}],"note":"a/b","reason":"externalTempo","#
                + #""seq":1,"to":2}"#)
    }

    @Test func generationV1RecordNamesEveryReasonAsTheSchemaDoes() throws {
        let reasons: [(GenerationBumpReason, String)] = [
            (.deviceRestart, "deviceRestart"), (.rateChange(nominalRate: 48_000), "rateChange"),
            (.configurationChange, "configurationChange"), (.wake, "wake"), (.locate(ticks: 0), "locate"),
            (.clockRestart, "clockRestart"), (.transportRestart, "transportRestart"), (.tempoEdit, "tempoEdit"),
            (.externalTempo, "externalTempo"), (.sourceLost, "sourceLost"),
            (.sourceReacquired, "sourceReacquired"), (.contextChange, "contextChange"), (.userCancel, "userCancel")
        ]
        #expect(Set(reasons.map(\.1)).count == 13)
        for (reason, name) in reasons {
            #expect(reason.contractV1Name == name)
        }
    }

    @Test func generationV1RecordRefusesInOrderWithoutClampingOrRemapping() throws {
        let sample = GenerationKey(.sampleClock, primary), mapKey = GenerationKey(.musicalMap, musicalClock)
        let badKey = GenerationKey(.sampleClock, GenerationSubject(validated: "Smp.main"))
        let revised = try MusicalMap(clock: musicalClock, revision: Generation(2),
                                     segments: [TempoSegment(atTicks: 0, microsPerQuarter: 500_000)])
        let meter = try MusicalMeter(MeterFields(numerator: 3, denominator: 4))
        #expect(try generationRefusal(badKey, .tempoEdit, 1, 3, seq: 0, note: "") == .invalidSeq(0))
        #expect(try generationRefusal(sample, .wake, seq: -1) == .invalidSeq(-1))
        #expect(try generationRefusal(badKey, .tempoEdit, 1, 3, note: "") == .invalidCounterSubject(badKey))
        for raw: StaticString in ["smp_main", "smp", "smp.", "1smp.a", "smp:1.a"] {
            let key = GenerationKey(.source, GenerationSubject(validated: raw))
            #expect(try generationRefusal(key, .sourceLost) == .invalidCounterSubject(key))
        }
        #expect(try generationRefusal(sample, .tempoEdit, 1, 3) == .reasonDoesNotMatchKind(sample, .tempoEdit))
        #expect(try generationRefusal(transportKey, .wake) == .reasonDoesNotMatchKind(transportKey, .wake))
        for (from, to) in [(1, 3), (2, 2), (2, 1), (1, 1)] {
            #expect(try generationRefusal(sample, .rateChange(nominalRate: 1), from, to) ==
                    .notConsecutive(from: Generation(from), to: Generation(to)))
        }
        for rate in [0, 47_999, 48_001, 22_050, 384_000] {
            #expect(try generationRefusal(sample, .rateChange(nominalRate: rate), map: revised) == .invalidRate(rate))
        }
        #expect(try generationRefusal(mapKey, .tempoEdit, meter: meter, note: "") == .musicalMapRequired)
        #expect(try generationRefusal(sample, .wake, map: revised, note: "") == .musicalMapNotAllowed)
        #expect(try generationRefusal(transportKey, .locate(ticks: 0), meter: meter) == .musicalMapNotAllowed)
        #expect(try generationRefusal(mapKey, .tempoEdit, 1, 2, map: tempoMap(), note: "") == .musicalMapMismatch)
        let foreign = try MusicalMap(clock: ClockID(validated: "mus.other"), revision: Generation(2),
                                     segments: revised.segments)
        #expect(try generationRefusal(mapKey, .externalTempo, map: foreign) == .musicalMapMismatch)
        let extended = try MusicalMap(clock: musicalClock, revision: Generation(2), segments: [
            TempoSegment(TempoSegmentFields(atTicks: 0, microsPerQuarter: 500_000), unknownFields: ["x": .bool(true)])
        ])
        #expect(try generationRefusal(mapKey, .tempoEdit, map: extended, note: "") == .musicalMapExtensionFields)
        let extendedMeter = try MusicalMeter(MeterFields(numerator: 3, denominator: 4), unknownFields: ["x": .null])
        #expect(try generationRefusal(mapKey, .tempoEdit, map: revised, meter: extendedMeter) ==
                .musicalMapExtensionFields)
        #expect(try generationRefusal(mapKey, .tempoEdit, map: revised, meter: meter, note: "") ==
                .invalidNote(bytes: 0))
        #expect(try generationRefusal(sample, .wake, note: " \n\t") == .invalidNote(bytes: 3))
        let limit = GenerationV1Record.maximumNoteBytes
        #expect(limit == RecordingTakeV1Record.maximumNoteBytes && limit == 256)
        #expect(try generationRefusal(sample, .wake, note: String(repeating: "a", count: limit + 1)) ==
                .invalidNote(bytes: 257))
        #expect(try generationRefusal(sample, .wake, note: String(repeating: "é", count: 129)) ==
                .invalidNote(bytes: 258))
        #expect(try generationRefusal(sample, .wake, note: String(repeating: "a", count: limit)) == nil)
        #expect(try generationRefusal(sample, .wake, note: String(repeating: "é", count: 128)) == nil)
        let top = Generation.maximumValue
        #expect(try generationRefusal(sample, .wake, top - 1, top) == nil)
        #expect(try generationRefusal(sample, .wake, top, top) ==
                .notConsecutive(from: Generation(top), to: Generation(top)))
    }

    @Test func generationV1RecordWritesTheRateOnlyForARateChangeAndDropsLocateTicks() throws {
        let sample = GenerationKey(.sampleClock, primary)
        for reason: GenerationBumpReason in [.deviceRestart, .configurationChange, .wake] {
            let record = try GenerationV1Record.make(counter: sample, from: .initial, to: Generation(2),
                                                     reason: reason, seq: 1)
            #expect(record.nominalRate == nil && record.musicalMap == nil && record.meter == nil)
        }
        for rate in [44_100, 48_000, 88_200, 96_000, 176_400, 192_000] {
            let record = try GenerationV1Record.make(counter: sample, from: .initial, to: Generation(2),
                                                     reason: .rateChange(nominalRate: rate), seq: 1)
            #expect(record.nominalRate == rate)
        }
        let near = try GenerationV1Record.make(counter: transportKey, from: .initial, to: Generation(2),
                                               reason: .locate(ticks: 0), seq: 12)
        let far = try GenerationV1Record.make(counter: transportKey, from: .initial, to: Generation(2),
                                              reason: .locate(ticks: 61_440), seq: 12)
        #expect(try near.encodedJSON() == far.encodedJSON())
    }
}
