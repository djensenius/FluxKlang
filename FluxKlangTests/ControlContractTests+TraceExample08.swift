//
//  ControlContractTests+TraceExample08.swift
//  FluxKlangTests
//
//  Media contract example 08 (#84 EXG4) rebuilt from the v1 trace builders: the `clocks`, `streams`,
//  `initialGenerations` and `timeline` sections, each record kind of the timeline, and the whole document, all
//  compared with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed
//  value; nothing is decoded from the example and nothing is read from disk. One `TakeLedger` records two takes:
//  `tk.1` (split by a clock restart, ended by a full disk) and the later `tk.2` (ended by a lost device). The
//  timeline interleaves the ledger's records with the generation bump and the restart, which are built by hand.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/08-audio-capture-discontinuities.json, whose SHA-256 is
//  74bd8842d6e3acb70b788dc3c6db3872b218e96a58296b64866a29401beb39f3. No builder produces the keys `contract`,
//  `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixture = TakeLedgerTestFixture

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let takeIn = StreamID(validated: "str.take-in")
private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "streams", "initialGenerations", "timeline"]
private let exampleKinds = [
    "anchor", "discontinuity", "generation", "discontinuity", "anchor",
    "discontinuity", "discontinuity", "take", "discontinuity", "take"
]
private let diskFullNote = "Writer finalised the partial file."
private let latencyNote = "Reported latency is not measured latency; no loopback measurement was made."

// swiftlint:disable line_length
private let example08 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.08-audio-capture-discontinuities",
  "title": "Audio capture: overflow padding, a 48 kHz to 96 kHz restart of the same clock splits the take, disk full leaves a recoverable partial file; a later clean take has its own stop",
  "covers": ["capture", "clockRestart"],
  "notes": [
    "Overflow never blocks the render thread: dropped frames are padded with silence in the file and counted.",
    "No padding spans a clock restart; startOffsetNs aligns segments to the first one, so the take stores no absolute host ticks.",
    "smp.main restarts at 96 kHz (rateChange): generation 2 converts at 96 kHz while segment 1 keeps its 48 kHz alignment.",
    "tk.2 records later on the same stream: tk.1's overflow and disk-full stop lie outside its recording interval, and its own deviceLost stop is checked against it alone."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "streams": [{"streamId": "str.take-in", "ordinal": 0, "media": "audio", "direction": "capture"}],
  "initialGenerations": {"sampleClock/smp.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 48000, "hostTicks": 2424000000},
    {"seq": 2, "kind": "discontinuity", "type": "overflow", "sampleClock": "smp.main", "generation": 1, "frame": 480000, "frames": 1024, "stream": "str.take-in"},
    {"seq": 3, "kind": "generation", "counter": "sampleClock/smp.main", "from": 1, "to": 2, "reason": "rateChange", "nominalRate": 96000},
    {"seq": 4, "kind": "discontinuity", "type": "clockRestart", "sampleClock": "smp.main", "generation": 2, "frame": 0, "hostTicks": 2900000000, "previousFrame": 960000},
    {"seq": 5, "kind": "anchor", "sampleClock": "smp.main", "generation": 2, "frame": 96000, "hostTicks": 2924000000},
    {"seq": 6, "kind": "discontinuity", "type": "overflow", "sampleClock": "smp.main", "generation": 2, "frame": 192000, "frames": 512, "stream": "str.take-in"},
    {"seq": 7, "kind": "discontinuity", "type": "captureStopped", "sampleClock": "smp.main", "generation": 2, "frame": 480000, "stream": "str.take-in", "reason": "diskFull", "note": "Writer finalised the partial file."},
    {"seq": 8, "kind": "take", "takeId": "tk.1", "stream": "str.take-in", "inputLatency": {"reportedFrames": 312, "measuredFrames": null}, "segments": [{"sampleClock": "smp.main", "generation": 1, "startFrame": 0, "startOffsetNs": 0, "fileFrameStart": 0, "frames": 960000, "paddedFrames": 1024}, {"sampleClock": "smp.main", "generation": 2, "startFrame": 0, "startOffsetNs": 20833333333, "fileFrameStart": 960000, "frames": 480000, "paddedFrames": 512}], "droppedFrames": 1536, "stopReason": "diskFull", "note": "Reported latency is not measured latency; no loopback measurement was made."},
    {"seq": 9, "kind": "discontinuity", "type": "captureStopped", "sampleClock": "smp.main", "generation": 2, "frame": 720000, "stream": "str.take-in", "reason": "deviceLost"},
    {"seq": 10, "kind": "take", "takeId": "tk.2", "stream": "str.take-in", "inputLatency": {"reportedFrames": 312, "measuredFrames": null}, "segments": [{"sampleClock": "smp.main", "generation": 2, "startFrame": 600000, "startOffsetNs": 0, "fileFrameStart": 0, "frames": 120000, "paddedFrames": 0}], "droppedFrames": 0, "stopReason": "deviceLost"}]}
"""#
// swiftlint:enable line_length

// MARK: - Canonical form

/// Parses JSON bytes; `JSONSerialization` keeps booleans and numbers apart, which `NSDictionary ==` does not.
private func parse(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// The bytes of `object` re-serialized with sorted keys.
private func canonical(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
}

private func canonical(builderBytes data: Data) throws -> Data {
    try canonical(parse(data))
}

private func exampleObject() throws -> [String: Any] {
    try #require(try parse(Data(example08.utf8)) as? [String: Any])
}

/// One section of the example, in canonical form.
private func exampleSection(_ key: String) throws -> Data {
    try canonical(#require(exampleObject()[key], "\(key)"))
}

// MARK: - Builder inputs

private func clocksRecord() throws -> ClocksV1Record {
    let fields = try TransportFields(
        host: .init(host: HostID(validated: "host.test"), generation: .initial),
        primaryClock: smpMain, sampleGeneration: .initial, nominalRate: 48_000, musicalClock: musMain,
        transportGeneration: .initial, musicalMapRevision: .initial,
        segments: [TempoSegment(.init(atTicks: 0, microsPerQuarter: 500_000), unknownFields: [:])],
        meter: MusicalMeter(.init(numerator: 4, denominator: 4)), loop: nil)
    let transport = try TransportDocument(revision: .initial, payload: ControlRecord(fields))
    return try ClocksV1Record.make(transport: transport, timebase: HostTimebase(numer: 125, denom: 3))
}

private func streamsRecord(direction: StreamsV1Record.Direction = .capture) throws -> StreamsV1Record {
    try StreamsV1Record.make([.init(id: takeIn, ordinal: 0, media: .audio, direction: direction)])
}

/// Two counters only: example 08 has no transport, so `musicalClock` is not checked against any counter.
private func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, smpMain): .initial,
        GenerationKey(.context, ClockID(validated: "ctx.main")): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

/// Both takes of the example, from ONE ledger. The expectations prove the sequence ran: `tk.1` is finished by the
/// disk-full stop, then `tk.2` opens later on the same stream and owns only its own `deviceLost` stop.
private func twoTakes() throws -> (first: RecordingTake, second: RecordingTake) {
    var ledger = try Fixture.example08Take1()
    let first = try ledger.finish(Fixture.take1, reason: .diskFull)
    try ledger.open(Fixture.opening(Fixture.take2, 2, 600_000))
    try ledger.advance(Fixture.take2, to: Fixture.stamp(2, 720_000))
    #expect(try ledger.ingest(Fixture.stop(2, 720_000, .deviceLost)) == [.recorded(Fixture.take2)])
    let second = try ledger.finish(Fixture.take2, reason: .deviceLost)
    return (first, second)
}

private func anchorEntry(generation: Generation, frame: Int64, hostTicks: UInt64, seq: Int) throws -> TimelineV1Entry {
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: generation, frame: frame),
                             host: HostStamp(ticks: hostTicks))
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

/// The ten entries of the example: the ledger's records interleaved with the hand-built generation and restart.
private func timelineEntries(restartPreviousFrame: Int64 = 960_000) throws -> [TimelineV1Entry] {
    let second = try Generation.initial.next()
    let (first, later) = try twoTakes()
    let clearance1 = try RecordingTakeV1Gate.clear(first)
    let clearance2 = try RecordingTakeV1Gate.clear(later)
    #expect(RecordingTakeV1Discontinuities.count(of: clearance1) == 3)
    #expect(RecordingTakeV1Discontinuities.count(of: clearance2) == 1)
    let stops1 = try RecordingTakeV1Discontinuities.make(clearance1, seqs: [2, 6, 7], notes: [7: diskFullNote])
    let stops2 = try RecordingTakeV1Discontinuities.make(clearance2, seqs: [9])
    try #require(stops1.count == 3 && stops2.count == 1)
    let bump = try GenerationV1Record.make(
        counter: GenerationKey(.sampleClock, smpMain), from: .initial, to: second,
        reason: .rateChange(nominalRate: 96_000), seq: 3)
    let restart = try DiscontinuityV1Record.make(
        .clockRestart(hostTicks: 2_900_000_000, previousFrame: restartPreviousFrame),
        sampleClock: smpMain, generation: second, frame: 0, seq: 4)
    let take1 = try RecordingTakeV1Record.make(clearance1, seq: 8, note: latencyNote)
    let take2 = try RecordingTakeV1Record.make(clearance2, seq: 10, note: nil)
    return try [
        anchorEntry(generation: .initial, frame: 48_000, hostTicks: 2_424_000_000, seq: 1),
        .discontinuity(stops1[0]), .generation(bump), .discontinuity(restart),
        anchorEntry(generation: second, frame: 96_000, hostTicks: 2_924_000_000, seq: 5),
        .discontinuity(stops1[1]), .discontinuity(stops1[2]), .take(take1),
        .discontinuity(stops2[0]), .take(take2)
    ]
}

private func timelineRecord(restartPreviousFrame: Int64 = 960_000) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(restartPreviousFrame: restartPreviousFrame))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(restartPreviousFrame: Int64 = 960_000) throws -> Data {
    var document: [String: Any] = [:]
    let example = try exampleObject()
    for key in exampleOnlyKeys {
        guard let value = example[key] else {
            Issue.record("the example has no \(key)")
            continue
        }
        document[key] = value
    }
    document["clocks"] = try parse(clocksRecord().encodedJSON())
    document["streams"] = try parse(streamsRecord().encodedJSON())
    document["initialGenerations"] = try parse(initialGenerationsRecord().encodedJSON())
    document["timeline"] = try parse(timelineRecord(restartPreviousFrame: restartPreviousFrame).encodedJSON())
    return try canonical(document)
}

/// The example's timeline records of the given `kind`, in seq order, with the entries built for them.
private func timelineRecords(kind: String) throws -> (example: [Data], built: [Data]) {
    let records = try #require(exampleObject()["timeline"] as? [[String: Any]])
    let entries = try timelineEntries()
    try #require(records.count == entries.count)
    var example: [Data] = [], built: [Data] = []
    for (record, entry) in zip(records, entries) where record["kind"] as? String == kind {
        example.append(try canonical(record))
        built.append(try canonical(builderBytes: ContractCoding.makeEncoder().encode(entry)))
    }
    return (example, built)
}

extension ControlContractTests {
    struct TraceExample08 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + exampleOnlyKeys))
            #expect(keys.count == 10)
            #expect(!keys.contains("actions"))
        }

        @Test func clocksSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: clocksRecord().encodedJSON())
            #expect(built == (try exampleSection("clocks")))
        }

        @Test func streamsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: streamsRecord().encodedJSON())
            #expect(built == (try exampleSection("streams")))
            let section = try #require(exampleObject()["streams"] as? [[String: Any]])
            try #require(section.count == 1)
            #expect(section.first?["direction"] as? String == "capture")
        }

        @Test func initialGenerationsSectionHasTwoCountersAndNoTransportCounter() throws {
            let built = try canonical(builderBytes: initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
            let section = try #require(exampleObject()["initialGenerations"] as? [String: Any])
            #expect(Set(section.keys) == ["sampleClock/smp.main", "context/ctx.main"])
        }

        @Test func timelineSectionEqualsTheBuilderOverTenEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...10))
            #expect(entries.map(\.kind) == exampleKinds)
            let records = try #require(exampleObject()["timeline"] as? [[String: Any]])
            #expect(records.compactMap { $0["kind"] as? String } == exampleKinds)
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func discontinuityRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "discontinuity")
            #expect(records.example.count == 5)
            #expect(records.built == records.example)
        }

        @Test func generationRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "generation")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        /// `measuredFrames: null` must survive: the comparison would fail if the builder wrote 0 or no key.
        @Test func takeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "take")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
            let timeline = try #require(exampleObject()["timeline"] as? [[String: Any]])
            for take in timeline where take["kind"] as? String == "take" {
                let latency = try #require(take["inputLatency"] as? [String: Any])
                #expect(latency["measuredFrames"] is NSNull)
            }
        }

        @Test func theTwoTakesComeFromOneLedgerAndTheSecondOwnsOnlyItsOwnStop() throws {
            let (first, later) = try twoTakes()
            #expect(first.take == Fixture.take1 && later.take == Fixture.take2)
            #expect(first.segments.count == 2 && first.droppedFrames == 1536 && first.stopReason == .diskFull)
            #expect(later.segments.count == 1 && later.droppedFrames == 0 && later.stopReason == .deviceLost)
            let clearance1 = try RecordingTakeV1Gate.clear(first)
            let clearance2 = try RecordingTakeV1Gate.clear(later)
            #expect(RecordingTakeV1Discontinuities.count(of: clearance1) == 3)
            let stops = try RecordingTakeV1Discontinuities.make(clearance2, seqs: [9])
            let stop = try #require(stops.first)
            #expect(stops.count == 1 && stop.event == .captureStopped(takeIn, reason: .deviceLost))
            #expect(stop.frame == 720_000 && stop.generation.value == 2)
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            // The take records carry `measuredFrames: null`; a builder writing 0 or no key fails here too.
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(restartPreviousFrame: 960_001) != expected)
            #expect(try canonical(builderBytes: timelineRecord(restartPreviousFrame: 960_001).encodedJSON())
                != (try exampleSection("timeline")))
            #expect(try canonical(builderBytes: streamsRecord(direction: .playback).encodedJSON())
                != (try exampleSection("streams")))
        }
    }
}
