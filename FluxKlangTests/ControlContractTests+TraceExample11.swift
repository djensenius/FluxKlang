//
//  ControlContractTests+TraceExample11.swift
//  FluxKlangTests
//
//  Media contract example 11 (#84 EXG3) rebuilt from the v1 trace builders: the `clocks`, `streams`,
//  `initialGenerations` and `timeline` sections, each record kind of the timeline, and the whole document, all
//  compared with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed
//  value; nothing is decoded from the example and nothing is read from disk. The take and its two discontinuities
//  come from one `RecordingTake` that a `TakeLedger` ended.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/11-audio-capture-discontinuity-stop.json, whose SHA-256 is
//  cc914d07c228ed0de7e8aef1580812718981aea0042162ae2a5c292493d7fd35. No builder produces the keys `contract`,
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
private let stopNote = "The recorder ended the take: a sampleJump landed before its start, "
    + "so it keeps the audio up to this frame."

// swiftlint:disable line_length
private let example11 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.11-audio-capture-discontinuity-stop",
  "title": "Audio capture: a sampleJump before the take's start leaves it nowhere to continue, so the recorder ends it at its last good frame with the discontinuity stop reason",
  "covers": ["capture"],
  "notes": [
    "Neither the user nor the device stopped tk.1: a sampleJump landed before its start in its own generation, so the recorder ended it at its last good frame and kept the audio recorded up to there.",
    "stopReason is discontinuity and the take owns one captureStopped with the same reason at the end of its last segment, as every non-user stop does (example 08). It is not mapped to user, diskFull or deviceLost.",
    "The cause is not a contract field: the captureStopped note names it as prose. The stop and the take are the record; the checker needs no sampleJump record."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "streams": [{"streamId": "str.take-in", "ordinal": 0, "media": "audio", "direction": "capture"}],
  "initialGenerations": {"sampleClock/smp.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 48000, "hostTicks": 2424000000},
    {"seq": 2, "kind": "discontinuity", "type": "overflow", "sampleClock": "smp.main", "generation": 1, "frame": 120000, "frames": 512, "stream": "str.take-in"},
    {"seq": 3, "kind": "discontinuity", "type": "captureStopped", "sampleClock": "smp.main", "generation": 1, "frame": 240000, "stream": "str.take-in", "reason": "discontinuity", "note": "The recorder ended the take: a sampleJump landed before its start, so it keeps the audio up to this frame."},
    {"seq": 4, "kind": "take", "takeId": "tk.1", "stream": "str.take-in", "inputLatency": {"reportedFrames": 312, "measuredFrames": null}, "segments": [{"sampleClock": "smp.main", "generation": 1, "startFrame": 96000, "startOffsetNs": 0, "fileFrameStart": 0, "frames": 144000, "paddedFrames": 512}], "droppedFrames": 512, "stopReason": "discontinuity"}]}
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
    try #require(try parse(Data(example11.utf8)) as? [String: Any])
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

/// Two counters only: example 11 has no transport, so `musicalClock` is not checked against any counter.
private func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, smpMain): .initial,
        GenerationKey(.context, ClockID(validated: "ctx.main")): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

/// Example 11's `tk.1`: opened at frame 96000, 512 frames dropped at 120000, then a `sampleJump` to frame 48000
/// lands before its start and the ledger ends it at its last good frame, 240000. The expectations prove the sequence.
private func endedTake() throws -> RecordingTake {
    let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
    var ledger = try Fixture.ledger(at: 96_000)
    try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 120_512))
    #expect(try ledger.ingest(Fixture.overflow(1, 120_000, frames: 512)) == [.recorded(Fixture.take1)])
    try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 240_000))
    #expect(try ledger.ingest(Fixture.jump(1, 48_000)) == [.ended(Fixture.take1, ended)])
    return try ledger.finish(Fixture.take1, reason: ended)
}

private func anchorEntry(frame: Int64 = 48_000) throws -> TimelineV1Entry {
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: frame),
                             host: HostStamp(ticks: 2_424_000_000))
    return .anchor(try AnchorV1Record.make(anchor, seq: 1))
}

/// The four entries of the example, the three take records all derived from one take and one clearance.
private func timelineEntries(anchorFrame: Int64 = 48_000) throws -> [TimelineV1Entry] {
    let clearance = try RecordingTakeV1Gate.clear(endedTake())
    #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 2)
    let stops = try RecordingTakeV1Discontinuities.make(clearance, seqs: [2, 3], notes: [3: stopNote])
    let take = try RecordingTakeV1Record.make(clearance, seq: 4)
    return try [anchorEntry(frame: anchorFrame)] + stops.map { .discontinuity($0) } + [.take(take)]
}

private func timelineRecord(anchorFrame: Int64 = 48_000) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(anchorFrame: anchorFrame))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(anchorFrame: Int64 = 48_000) throws -> Data {
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
    document["timeline"] = try parse(timelineRecord(anchorFrame: anchorFrame).encodedJSON())
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
    struct TraceExample11 {
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
            #expect(section.count == 1)
            #expect(section.first?["direction"] as? String == "capture")
        }

        @Test func initialGenerationsSectionHasTwoCountersAndNoTransportCounter() throws {
            let built = try canonical(builderBytes: initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
            let section = try #require(exampleObject()["initialGenerations"] as? [String: Any])
            #expect(Set(section.keys) == ["sampleClock/smp.main", "context/ctx.main"])
        }

        @Test func timelineSectionEqualsTheBuilderOverFourEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...4))
            #expect(entries.map(\.kind) == ["anchor", "discontinuity", "discontinuity", "take"])
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func discontinuityRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "discontinuity")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        /// `measuredFrames: null` must survive: the comparison would fail if the builder wrote 0 or no key.
        @Test func takeRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "take")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
            let take = try #require(exampleObject()["timeline"] as? [[String: Any]]).last
            let latency = try #require(take?["inputLatency"] as? [String: Any])
            #expect(latency["measuredFrames"] is NSNull)
        }

        @Test func theTakeCarriesTheDiscontinuityStopReasonItsCaptureStoppedNames() throws {
            let entries = try timelineEntries()
            try #require(entries.count == 4)
            guard case .take(let take) = try #require(entries.last),
                  case .discontinuity(let stop) = entries[2] else {
                Issue.record("entries 3 and 4 are a discontinuity and a take")
                return
            }
            #expect(take.stopReason == "discontinuity")
            #expect(stop.event == .captureStopped(takeIn, reason: .discontinuity))
            #expect(take.droppedFrames == 512 && take.segments.count == 1)
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(anchorFrame: 48_001) != expected)
            #expect(try canonical(builderBytes: timelineRecord(anchorFrame: 48_001).encodedJSON())
                != (try exampleSection("timeline")))
            #expect(try canonical(builderBytes: streamsRecord(direction: .playback).encodedJSON())
                != (try exampleSection("streams")))
        }
    }
}
