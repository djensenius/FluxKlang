//
//  ControlContractTests+TraceExample12.swift
//  FluxKlangTests
//
//  Media contract example 12 (#84 EXG3) rebuilt from the v1 trace builders: the `clocks`, `streams`,
//  `initialGenerations` and `timeline` sections, each record kind of the timeline, and the whole document, all
//  compared with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed
//  value; nothing is decoded from the example and nothing is read from disk. The take and its overflow come from
//  one `RecordingTake` that a `TakeLedger` split at a forward sample jump; the `sampleJump` record is stated from
//  the boundary the ledger kept.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/12-audio-capture-sample-jump-split.json, whose SHA-256 is
//  81162baa0df5c7708fc2584ade3a4cd4eb9bd0258333d0e7ea45d5b78b5d88af. No builder produces the keys `contract`,
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
private let jumpNote = "The device's frame counter jumped forward: frame 240000 is the first frame after the jump."

// swiftlint:disable line_length
private let example12 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.12-audio-capture-sample-jump-split",
  "title": "Audio capture: a forward sampleJump splits one take into two segments of the same generation, and gapFrames names the frames that were never captured",
  "covers": ["capture"],
  "notes": [
    "The device's frame counter jumped forward by 144000 frames inside one sample clock generation, with no clock restart: tk.1 continues, in a new segment that starts at the jump's frame.",
    "Segment 1 states the gap in gapFrames. The file stays contiguous (fileFrameStart does not advance), the gap is not padded and not counted in droppedFrames: those frames were never captured, and gapFrames and the sampleJump record are what say so.",
    "Segment 1's startOffsetNs includes the gap's wall time (the same generation's anchor maps both starts): 120000000 host ticks of 125/3 ns are 5000000000 ns."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "streams": [{"streamId": "str.take-in", "ordinal": 0, "media": "audio", "direction": "capture"}],
  "initialGenerations": {"sampleClock/smp.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 48000, "hostTicks": 2424000000},
    {"seq": 2, "kind": "discontinuity", "type": "overflow", "sampleClock": "smp.main", "generation": 1, "frame": 48000, "frames": 512, "stream": "str.take-in"},
    {"seq": 3, "kind": "discontinuity", "type": "sampleJump", "sampleClock": "smp.main", "generation": 1, "frame": 240000, "note": "The device's frame counter jumped forward: frame 240000 is the first frame after the jump."},
    {"seq": 4, "kind": "take", "takeId": "tk.1", "stream": "str.take-in", "inputLatency": {"reportedFrames": 312, "measuredFrames": null}, "segments": [{"sampleClock": "smp.main", "generation": 1, "startFrame": 0, "startOffsetNs": 0, "fileFrameStart": 0, "frames": 96000, "paddedFrames": 512}, {"sampleClock": "smp.main", "generation": 1, "startFrame": 240000, "gapFrames": 144000, "startOffsetNs": 5000000000, "fileFrameStart": 96000, "frames": 96000, "paddedFrames": 0}], "droppedFrames": 512, "stopReason": "user"}]}
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
    try #require(try parse(Data(example12.utf8)) as? [String: Any])
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

/// Two counters only: example 12 has no transport, so `musicalClock` is not checked against any counter.
private func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, smpMain): .initial,
        GenerationKey(.context, ClockID(validated: "ctx.main")): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

/// Example 12's `tk.1`: opened at frame 0, 512 frames dropped at 48000, then a forward `sampleJump` to frame 240000
/// splits it, and the user stops it at 336000. The expectations prove the sequence.
private func splitTake() throws -> RecordingTake {
    var ledger = try Fixture.ledger(at: 0)
    try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 48_512))
    #expect(try ledger.ingest(Fixture.overflow(1, 48_000, frames: 512)) == [.recorded(Fixture.take1)])
    try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 96_000))
    #expect(try ledger.ingest(Fixture.jump(1, 240_000)) == [.split(Fixture.take1)])
    try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 336_000))
    return try ledger.finish(Fixture.take1, reason: .user)
}

private func anchorEntry(frame: Int64 = 48_000) throws -> TimelineV1Entry {
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: frame),
                             host: HostStamp(ticks: 2_424_000_000))
    return .anchor(try AnchorV1Record.make(anchor, seq: 1))
}

/// The four entries of the example, the overflow, the jump and the take all derived from one take.
private func timelineEntries(anchorFrame: Int64 = 48_000, note: String = jumpNote) throws -> [TimelineV1Entry] {
    let take = try splitTake()
    let boundary = try #require(take.boundaries.first)
    #expect(take.boundaries.count == 1 && boundary.reason == .sampleJump)
    let clearance = try RecordingTakeV1Gate.clear(take)
    #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 1)
    let overflows = try RecordingTakeV1Discontinuities.make(clearance, seqs: [2])
    let jump = try DiscontinuityV1Record.make(.sampleJump, sampleClock: Fixture.clock, generation: boundary.generation,
                                              frame: boundary.frame, seq: 3, note: note)
    let record = try RecordingTakeV1Record.make(clearance, seq: 4)
    return try [anchorEntry(frame: anchorFrame)] + overflows.map { .discontinuity($0) }
        + [.discontinuity(jump), .take(record)]
}

private func timelineRecord(anchorFrame: Int64 = 48_000, note: String = jumpNote) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(anchorFrame: anchorFrame, note: note))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(note: String = jumpNote) throws -> Data {
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
    document["timeline"] = try parse(timelineRecord(note: note).encodedJSON())
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
    struct TraceExample12 {
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
        @Test func takeRecordEqualsTheExampleRecordWithBothSegments() throws {
            let records = try timelineRecords(kind: "take")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
            let take = try #require(exampleObject()["timeline"] as? [[String: Any]]).last
            let latency = try #require(take?["inputLatency"] as? [String: Any])
            #expect(latency["measuredFrames"] is NSNull)
            #expect((take?["segments"] as? [Any])?.count == 2)
        }

        @Test func theSampleJumpNamesNoStreamAndTheGapIsNotDropped() throws {
            let entries = try timelineEntries()
            try #require(entries.count == 4)
            guard case .discontinuity(let jump) = entries[2], case .take(let take) = try #require(entries.last) else {
                Issue.record("entries 3 and 4 are a discontinuity and a take")
                return
            }
            #expect(jump.event == .sampleJump && jump.frame == 240_000 && jump.note == jumpNote)
            #expect(take.segments.map(\.gapFrames) == [nil, 144_000])
            #expect(take.droppedFrames == 512 && take.stopReason == "user")
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(note: "other") != expected)
            #expect(try canonical(builderBytes: timelineRecord(anchorFrame: 48_001).encodedJSON())
                != (try exampleSection("timeline")))
            #expect(try canonical(builderBytes: streamsRecord(direction: .playback).encodedJSON())
                != (try exampleSection("streams")))
        }
    }
}
