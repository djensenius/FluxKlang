//
//  ControlContractTests+ClocksV1.swift
//  FluxKlangTests
//
//  The media contract v1 trace header `clocks` builder (#84 CXR1): golden example headers byte for byte, extra
//  sample clocks after the primary, tempo map order, the loop, tick edges, the refusal order and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = ClocksV1RecordRefusal
private typealias SampleClock = ClocksV1Record.SampleClock

private let smpMain = ClockID(validated: "smp.main")
private let smpAux = ClockID(validated: "smp.aux")
private let smpThird = ClockID(validated: "smp.third")
private let musMain = ClockID(validated: "mus.main")
/// The example timebase: 125/3 ns per tick (24 MHz).
private let exampleTimebase = HostTimebase(numer: 125, denom: 3)

private func segment(_ atTicks: Int64, _ microsPerQuarter: Int64 = 500_000,
                     extra: [String: JSONValue] = [:]) throws -> TempoSegment {
    try TempoSegment(.init(atTicks: atTicks, microsPerQuarter: microsPerQuarter), unknownFields: extra)
}

private func clocksTransport(primary: ClockID = smpMain, rate: Int = 48_000, musical: ClockID? = musMain,
                             segments: [TempoSegment]? = nil, meter: MusicalMeter? = nil,
                             loop: LoopRange? = nil) throws -> TransportDocument {
    let hasMusic = musical != nil
    let fields = try TransportFields(
        host: .init(host: HostID(validated: "host.test"), generation: .initial),
        primaryClock: primary, sampleGeneration: .initial, nominalRate: rate, musicalClock: musical,
        transportGeneration: hasMusic ? .initial : nil, musicalMapRevision: hasMusic ? .initial : nil,
        segments: segments ?? (hasMusic ? [segment(0)] : []),
        meter: meter ?? (hasMusic ? MusicalMeter(.init(numerator: 4, denominator: 4)) : nil), loop: loop
    )
    return try TransportDocument(revision: .initial, payload: ControlRecord(fields))
}

private func clocksRefusal(_ transport: TransportDocument, timebase: HostTimebase = exampleTimebase,
                           extra: [SampleClock] = []) -> Refusal? {
    do {
        _ = try ClocksV1Record.make(transport: transport, timebase: timebase, extraSampleClocks: extra)
        return nil
    } catch {
        return error
    }
}

private func clocksJSON(_ record: ClocksV1Record) throws -> String {
    try #require(String(data: record.encodedJSON(), encoding: .utf8))
}

/// `clocks` of examples 01–02, 04–08 and 10 (no loop), of example 03 (loop) and of example 09 (no loop, a tempo
/// of 3 000 000 µs per quarter), keys sorted, compact.
private let exampleClocksJSON = #"{"host":{"timebaseDenom":3,"timebaseNumer":125},"musical":{"clockId":"mus.main","#
    + #""meter":{"denominator":4,"numerator":4},"musicalMap":[{"atTicks":0,"microsPerQuarter":500000}],"#
    + #""ticksPerQuarter":15360},"sample":[{"clockId":"smp.main","nominalRate":48000}]}"#
private let exampleLoopClocksJSON = #"{"host":{"timebaseDenom":3,"timebaseNumer":125},"musical":{"clockId":"mus.main","#
    + #""loop":{"endTicks":122880,"startTicks":0},"meter":{"denominator":4,"numerator":4},"#
    + #""musicalMap":[{"atTicks":0,"microsPerQuarter":500000}],"ticksPerQuarter":15360},"#
    + #""sample":[{"clockId":"smp.main","nominalRate":48000}]}"#
private let example09ClocksJSON = #"{"host":{"timebaseDenom":3,"timebaseNumer":125},"musical":{"clockId":"mus.main","#
    + #""meter":{"denominator":4,"numerator":4},"musicalMap":[{"atTicks":0,"microsPerQuarter":3000000}],"#
    + #""ticksPerQuarter":15360},"sample":[{"clockId":"smp.main","nominalRate":48000}]}"#

extension ControlContractTests {
    struct ClocksV1 {
        @Test func clocksV1RecordEncodesTheExampleHeadersExactly() throws {
            let plain = try ClocksV1Record.make(transport: clocksTransport(), timebase: exampleTimebase)
            #expect(try clocksJSON(plain) == exampleClocksJSON)
            #expect(plain.loop == nil && plain.sample == [SampleClock(clockID: smpMain, nominalRate: 48_000)])
            let looped = try ClocksV1Record.make(
                transport: clocksTransport(loop: LoopRange(startTicks: 0, endTicks: 122_880)), timebase: exampleTimebase
            )
            #expect(try clocksJSON(looped) == exampleLoopClocksJSON)
            #expect(looped.loop == ClocksV1Record.LoopRecord(startTicks: 0, endTicks: 122_880))
            let slow = try ClocksV1Record.make(transport: clocksTransport(segments: [segment(0, 3_000_000)]),
                                               timebase: exampleTimebase)
            #expect(try clocksJSON(slow) == example09ClocksJSON)
            for record in [plain, looped] {
                let again = try ClocksV1Record.make(transport: clocksTransport(loop: record.loop == nil ? nil
                                                        : LoopRange(startTicks: 0, endTicks: 122_880)),
                                                    timebase: exampleTimebase)
                #expect(again == record)
                #expect(try again.encodedJSON() == record.encodedJSON())
            }
        }

        @Test func clocksV1RecordWritesExactlyTheSchemaKeys() throws {
            let looped = try ClocksV1Record.make(
                transport: clocksTransport(loop: LoopRange(startTicks: 3, endTicks: 4)), timebase: exampleTimebase
            )
            let decoded = try JSONSerialization.jsonObject(with: looped.encodedJSON()) as? [String: Any]
            let object = try #require(decoded)
            #expect(Set(object.keys) == ["host", "sample", "musical"]) // no initialGenerations
            let host = try #require(object["host"] as? [String: Any])
            #expect(Set(host.keys) == ["timebaseNumer", "timebaseDenom"])
            let musical = try #require(object["musical"] as? [String: Any])
            #expect(Set(musical.keys) == ["clockId", "ticksPerQuarter", "meter", "musicalMap", "loop"])
            #expect(musical["ticksPerQuarter"] as? Int == 15_360)
            let samples = try #require(object["sample"] as? [[String: Any]])
            try #require(samples.count == 1)
            #expect(Set(samples[0].keys) == ["clockId", "nominalRate"])
        }

        @Test func clocksV1ExtraSampleClocksFollowThePrimaryInOrder() throws {
            let extra = [SampleClock(clockID: smpThird, nominalRate: 192_000),
                         SampleClock(clockID: smpAux, nominalRate: 44_100)]
            let record = try ClocksV1Record.make(transport: clocksTransport(rate: 96_000),
                                                 timebase: .init(numer: 1, denom: 1), extraSampleClocks: extra)
            try #require(record.sample.count == 3)
            #expect(record.sample[0] == SampleClock(clockID: smpMain, nominalRate: 96_000)) // primary first
            #expect(Array(record.sample.dropFirst()) == extra) // not sorted by ID
            #expect(try clocksJSON(record).hasSuffix(
                #""sample":[{"clockId":"smp.main","nominalRate":96000},{"clockId":"smp.third","nominalRate":192000},"#
                    + #"{"clockId":"smp.aux","nominalRate":44100}]}"#
            ))
            for rate in [44_100, 48_000, 88_200, 96_000, 176_400, 192_000] {
                let aux = [SampleClock(clockID: smpAux, nominalRate: rate)]
                #expect(clocksRefusal(try clocksTransport(), extra: aux) == nil, "\(rate)")
            }
        }

        @Test func clocksV1TempoMapAndMeterAreCopiedInOrder() throws {
            let segments = try [segment(0, 3_000_000), segment(15_360, 60_000), segment(46_080, 428_571)]
            let meter = try MusicalMeter(.init(numerator: 7, denominator: 8))
            let record = try ClocksV1Record.make(transport: clocksTransport(segments: segments, meter: meter),
                                                 timebase: exampleTimebase)
            #expect(record.musicalMap.map(\.atTicks) == [0, 15_360, 46_080])
            #expect(record.musicalMap.map(\.microsPerQuarter) == [3_000_000, 60_000, 428_571])
            #expect(record.meter == ClocksV1Record.MeterRecord(numerator: 7, denominator: 8))
            #expect(try clocksJSON(record).contains(
                #""meter":{"denominator":8,"numerator":7},"musicalMap":[{"atTicks":0,"microsPerQuarter":3000000},"#
                    + #"{"atTicks":15360,"microsPerQuarter":60000},{"atTicks":46080,"microsPerQuarter":428571}],"#
            ))
        }

        /// Transport ticks already count 15 360 per quarter: they are written unconverted, up to `Int64.max`.
        @Test func clocksV1TicksAreWrittenUnconvertedAtTheEdges() throws {
            #expect(MusicalTime.ticksPerQuarter == ClocksV1Record.ticksPerQuarter)
            #expect(ClocksV1Record.ticksPerQuarter == 15_360)
            let top = Int64.max
            let edges: [(Int64, Int64)] = [(0, 1), (0, top), (top - 1, top), (15_359, 15_361)]
            for (start, end) in edges {
                let record = try ClocksV1Record.make(
                    transport: clocksTransport(segments: [segment(0), segment(top)],
                                               loop: LoopRange(startTicks: start, endTicks: end)),
                    timebase: exampleTimebase
                )
                #expect(record.loop == ClocksV1Record.LoopRecord(startTicks: start, endTicks: end))
                let json = try clocksJSON(record)
                #expect(json.contains(#""loop":{"endTicks":\#(end),"startTicks":\#(start)}"#), "\(start)")
                #expect(json.contains(#"{"atTicks":9223372036854775807,"microsPerQuarter":500000}"#), "\(start)")
            }
            let widest = try ClocksV1Record.make(transport: clocksTransport(),
                                                 timebase: .init(numer: .max, denom: .max))
            let widestHost = #"{"host":{"timebaseDenom":4294967295,"timebaseNumer":4294967295}"#
            #expect(try clocksJSON(widest).hasPrefix(widestHost))
        }

        @Test func clocksV1RecordRefusesEachOffence() throws {
            #expect(clocksRefusal(try clocksTransport(musical: nil)) == .missingMusicalClock)
            for (numer, denom): (UInt32, UInt32) in [(0, 1), (1, 0), (0, 0)] {
                #expect(clocksRefusal(try clocksTransport(), timebase: .init(numer: numer, denom: denom))
                            == .invalidTimebase(numer: numer, denom: denom))
            }
            for raw: StaticString in ["smp_main", "smp", "smp.", "1smp.a", "smp:1.a", "SMP.MAIN"] {
                let clock = ClockID(validated: raw)
                #expect(clocksRefusal(try clocksTransport(primary: clock)) == .invalidClockID(clock), "\(raw)")
                #expect(clocksRefusal(try clocksTransport(musical: clock)) == .invalidClockID(clock), "\(raw)")
                #expect(clocksRefusal(try clocksTransport(), extra: [SampleClock(clockID: clock, nominalRate: 48_000)])
                            == .invalidClockID(clock), "\(raw)")
            }
            for rate in [0, -48_000, 44_099, 192_001, 768_000] {
                #expect(clocksRefusal(try clocksTransport(), extra: [SampleClock(clockID: smpAux, nominalRate: rate)])
                            == .invalidRate(clock: smpAux, rate: rate), "\(rate)")
            }
            let auxTwice = [SampleClock(clockID: smpAux, nominalRate: 48_000),
                            SampleClock(clockID: smpAux, nominalRate: 96_000)]
            #expect(clocksRefusal(try clocksTransport(), extra: auxTwice) == .duplicateClockID(smpAux))
            #expect(clocksRefusal(try clocksTransport(), extra: [SampleClock(clockID: smpMain, nominalRate: 48_000)])
                        == .duplicateClockID(smpMain))
            #expect(clocksRefusal(try clocksTransport(), extra: [SampleClock(clockID: musMain, nominalRate: 48_000)])
                        == .duplicateClockID(musMain))
            let flag: [String: JSONValue] = ["future": .bool(true)]
            #expect(clocksRefusal(try clocksTransport(segments: [segment(0), segment(1, extra: flag)]))
                        == .extensionFields)
            #expect(clocksRefusal(try clocksTransport(meter: MusicalMeter(.init(numerator: 3, denominator: 4),
                                                                          unknownFields: flag))) == .extensionFields)
            var loop = try LoopRange(startTicks: 0, endTicks: 1)
            loop.unknownFields = flag
            #expect(clocksRefusal(try clocksTransport(loop: loop)) == .extensionFields)
        }

        @Test func clocksV1RecordRefusesInOrder() throws {
            let flag: [String: JSONValue] = ["future": .bool(true)]
            let badID = ClockID(validated: "Smp.aux")
            let worst = [SampleClock(clockID: badID, nominalRate: 1), SampleClock(clockID: smpMain, nominalRate: 2)]
            let tagged = try clocksTransport(segments: [segment(0, extra: flag)])
            let zero = HostTimebase(numer: 0, denom: 0)
            // Every field bad: each refusal appears once the earlier ones are fixed.
            #expect(clocksRefusal(try clocksTransport(musical: nil), timebase: zero, extra: worst)
                        == .missingMusicalClock)
            #expect(clocksRefusal(tagged, timebase: zero, extra: worst) == .invalidTimebase(numer: 0, denom: 0))
            #expect(clocksRefusal(tagged, extra: worst) == .invalidClockID(badID))
            let badRates = [SampleClock(clockID: smpAux, nominalRate: 1), SampleClock(clockID: smpMain, nominalRate: 2)]
            #expect(clocksRefusal(tagged, extra: badRates) == .invalidRate(clock: smpAux, rate: 1))
            let repeated = [SampleClock(clockID: smpAux, nominalRate: 48_000),
                            SampleClock(clockID: smpMain, nominalRate: 48_000)]
            #expect(clocksRefusal(tagged, extra: repeated) == .duplicateClockID(smpMain))
            #expect(clocksRefusal(tagged) == .extensionFields)
            // IDs in order: primary, extras, then the musical clock.
            let badMusic = ClockID(validated: "Mus.main")
            let badPrimary = ClockID(validated: "Smp.main")
            #expect(clocksRefusal(try clocksTransport(primary: badPrimary, musical: badMusic), extra: worst)
                        == .invalidClockID(badPrimary))
            #expect(clocksRefusal(try clocksTransport(musical: badMusic), extra: worst) == .invalidClockID(badID))
        }
    }
}
