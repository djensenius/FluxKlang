//
//  ControlContractTests+TraceExample10.swift
//  FluxKlangTests
//
//  Media contract example 10 (#84 EXG5) rebuilt from the v1 trace builders: the `clocks`, `streams`,
//  `initialGenerations` and `timeline` sections, each record kind of the timeline, and the whole document, all
//  compared with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed
//  value; nothing is decoded from the example and nothing is read from disk. The comparison is semantic: it does
//  not check the key order or the number spelling of the builders' bytes.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/10-midi2-capture-lossy-smf-export.json, whose SHA-256 is
//  9b10d2755f8678d83b7206645dfe7459f48660f5a0436fa2eed6f9522ac7e471. No builder produces the keys `contract`,
//  `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//
//  Limit: the example's SMF record (seq 12) says format 1 at division 960 with eight loss categories, which the
//  real exporter does not write (it writes format 0 at division 15360 and has no `timingQuantized`). It is built
//  here from a SYNTHETIC `SMFWriteResult` (a 14-byte header and typed losses), so this golden proves the RECORD
//  BUILDER only, not that the exporter produces those losses.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixture = MIDICaptureFixture

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "streams", "initialGenerations", "timeline"]
/// `MThd`, length 6, format 1 (bytes 8-9), two tracks, division 960 = 0x03C0 (bytes 12-13).
private let smfHeader: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 2, 0x03, 0xC0]
private let smfLosses: [SMFExportLoss: Int] = [
    .timingQuantized: 1, .velocityDownscaled: 2, .attributeDropped: 1, .perNoteDropped: 1, .valueDownscaled: 1,
    .noteOnVelocityRemapped: 1, .fidelityUnverified: 1, .umpOnlyDropped: 1]
private let unknownNote = "No endpoint protocol reported: treated as MIDI 1, unverified."
private let timestampNote = "MT 0x0 JR Timestamp: no Group field, so it never makes groups look merged."

// swiftlint:disable line_length
private let example10 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.10-midi2-capture-lossy-smf-export",
  "title": "Genuine MIDI 2.0 capture: native UMP export is lossless; SMF export names every loss",
  "covers": ["midi2Native", "smfExportLossy"],
  "notes": [
    "Losses: off-grid timing at division 960, 16-bit velocities (0x0100 is also remapped to 1), pitch attribute, per-note pitch bend, 32-bit CC74, a JR Timestamp SMF cannot carry.",
    "str.synth-legacy reads the MIDI 2.0 endpoint through a MIDI 1.0 port: the OS already reduced it to MIDI 1 and it is labelled so. str.synth-unknown reports no endpoint protocol, so SMF export flags its fidelity as unverified.",
    "All channel messages are in group 2 (nibble 1); the groupless MT 0x0 timestamp does not count as a second group, so nothing is flattened."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "streams": [
    {"streamId": "str.synth", "ordinal": 0, "media": "midi", "direction": "capture"},
    {"streamId": "str.synth-legacy", "ordinal": 1, "media": "midi", "direction": "capture"},
    {"streamId": "str.synth-unknown", "ordinal": 2, "media": "midi", "direction": "capture"}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "midiCapture", "stream": "str.synth", "ump": ["0x41903C03", "0xC9251E00"], "hostTicks": 2412002500, "frame": 24005, "musicalTicks": 15363, "endpointProtocol": "midi2", "portProtocol": "midi2", "translatedBy": "none", "effective": "midi2"},
    {"seq": 3, "kind": "midiCapture", "stream": "str.synth", "ump": ["0x41603C00", "0x80400000"], "hostTicks": 2418000000, "frame": 36000, "musicalTicks": 23040, "endpointProtocol": "midi2", "portProtocol": "midi2", "translatedBy": "none", "effective": "midi2"},
    {"seq": 4, "kind": "midiCapture", "stream": "str.synth", "ump": ["0x41B04A00", "0x9A3C5E71"], "hostTicks": 2424000000, "frame": 48000, "musicalTicks": 30720, "endpointProtocol": "midi2", "portProtocol": "midi2", "translatedBy": "none", "effective": "midi2"},
    {"seq": 5, "kind": "midiCapture", "stream": "str.synth", "ump": ["0x41904000", "0x01000000"], "hostTicks": 2430000000, "frame": 60000, "musicalTicks": 38400, "endpointProtocol": "midi2", "portProtocol": "midi2", "translatedBy": "none", "effective": "midi2"},
    {"seq": 6, "kind": "midiCapture", "stream": "str.synth", "ump": ["0x41803C00", "0x00000000"], "hostTicks": 2436000000, "frame": 72000, "musicalTicks": 46080, "endpointProtocol": "midi2", "portProtocol": "midi2", "translatedBy": "none", "effective": "midi2"},
    {"seq": 7, "kind": "midiCapture", "stream": "str.synth", "ump": ["0x41804000", "0x00000000"], "hostTicks": 2442000000, "frame": 84000, "musicalTicks": 53760, "endpointProtocol": "midi2", "portProtocol": "midi2", "translatedBy": "none", "effective": "midi2"},
    {"seq": 8, "kind": "midiCapture", "stream": "str.synth-legacy", "ump": ["0x21903C64"], "hostTicks": 2448000000, "frame": 96000, "musicalTicks": 61440, "endpointProtocol": "midi2", "portProtocol": "midi1", "translatedBy": "os", "effective": "midi1"},
    {"seq": 9, "kind": "midiCapture", "stream": "str.synth-unknown", "ump": ["0x41903C00", "0xC9240000"], "hostTicks": 2454000000, "frame": 108000, "musicalTicks": 69120, "endpointProtocol": "unknown", "portProtocol": "midi2", "translatedBy": "os", "effective": "midi1", "verified": false, "note": "No endpoint protocol reported: treated as MIDI 1, unverified."},
    {"seq": 10, "kind": "midiCapture", "stream": "str.synth", "ump": ["0x00201F40"], "hostTicks": 2460000000, "frame": 120000, "musicalTicks": 76800, "endpointProtocol": "midi2", "portProtocol": "midi2", "translatedBy": "none", "effective": "midi2", "note": "MT 0x0 JR Timestamp: no Group field, so it never makes groups look merged."},
    {"seq": 11, "kind": "export", "exportId": "exp.ump", "streams": ["str.synth"], "format": "nativeUmp", "origin": {"sampleClock": "smp.main", "generation": 1, "frame": 24000}, "offsetsNs": [104167, 250000000, 500000000, 750000000, 1000000000, 1250000000, 2000000000], "lossless": true, "losses": {}},
    {"seq": 12, "kind": "export", "exportId": "exp.smf", "streams": ["str.synth", "str.synth-legacy", "str.synth-unknown"], "format": "smf", "smfFormat": 1, "division": 960, "lossless": false, "losses": {"timingQuantized": 1, "velocityDownscaled": 2, "attributeDropped": 1, "perNoteDropped": 1, "valueDownscaled": 1, "noteOnVelocityRemapped": 1, "fidelityUnverified": 1, "umpOnlyDropped": 1}}]}
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
    try #require(try parse(Data(example10.utf8)) as? [String: Any])
}

/// One section of the example, in canonical form.
private func exampleSection(_ key: String) throws -> Data {
    try canonical(#require(exampleObject()[key], "\(key)"))
}

private func exampleRecords() throws -> [[String: Any]] {
    try #require(exampleObject()["timeline"] as? [[String: Any]])
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

private func streamsRecord() throws -> StreamsV1Record {
    try StreamsV1Record.make([
        StreamsV1Record.Stream(id: Fixture.synth, ordinal: 0, media: .midi, direction: .capture),
        StreamsV1Record.Stream(id: Fixture.legacy, ordinal: 1, media: .midi, direction: .capture),
        StreamsV1Record.Stream(id: Fixture.unknown, ordinal: 2, media: .midi, direction: .capture)])
}

private func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, smpMain): .initial,
        GenerationKey(.transport, musMain): .initial,
        GenerationKey(.musicalMap, musMain): .initial,
        GenerationKey(.context, ClockID(validated: "ctx.main")): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

private func anchorEntry() throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: 0),
                             host: HostStamp(ticks: 2_400_000_000), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: 1))
}

/// seq 2 to 10, in delivery order; the two notes belong to seq 9 and seq 10 only.
private func captureEntries(_ log: MIDICaptureLog) throws -> [TimelineV1Entry] {
    let notes: [Int: String] = [9: unknownNote, 10: timestampNote]
    return try log.records.enumerated().map { index, record in
        let seq = index + 2
        return .midiCapture(try MIDICaptureV1Record.make(record, seq: seq, note: notes[seq]))
    }
}

/// seq 11: the native export of `str.synth` only, anchored at generation 1 frame 24000.
private func nativeEntry(_ log: MIDICaptureLog, frame: Int64 = 24_000) throws -> TimelineV1Entry {
    let export = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.synth],
                                          origin: Fixture.origin(1, frame: frame))
    return .export(try NativeUMPExportV1Record.make(export, seq: 11))
}

/// seq 12: a synthetic format 1 file at division 960 with the eight typed losses. The real export yields the other
/// seven (it is format 0 at division 15360, so it has no `timingQuantized`).
private func smfEntry(header: [UInt8], losses: [SMFExportLoss: Int]) throws -> TimelineV1Entry {
    let file = SMFWriteResult(bytes: header, losses: SMFExportLossReport(losses: losses), reorderedItems: 0)
    return .smfExport(try SMFExportV1Record.make(file, streams: [Fixture.synth, Fixture.legacy, Fixture.unknown],
                                                 exportID: ExportID(validated: "exp.smf"), seq: 12))
}

/// The twelve entries of the example; the three parameters are the inputs the negative check changes.
private func timelineEntries(header: [UInt8] = smfHeader, losses: [SMFExportLoss: Int] = smfLosses,
                             originFrame: Int64 = 24_000) throws -> [TimelineV1Entry] {
    let log = try Fixture.example10()
    return try [anchorEntry()] + captureEntries(log) + [
        try nativeEntry(log, frame: originFrame),
        try smfEntry(header: header, losses: losses)]
}

private func timelineRecord(header: [UInt8] = smfHeader, losses: [SMFExportLoss: Int] = smfLosses,
                            originFrame: Int64 = 24_000) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(header: header, losses: losses, originFrame: originFrame))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(header: [UInt8] = smfHeader, losses: [SMFExportLoss: Int] = smfLosses,
                             originFrame: Int64 = 24_000) throws -> Data {
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
    let timeline = try timelineRecord(header: header, losses: losses, originFrame: originFrame)
    document["timeline"] = try parse(timeline.encodedJSON())
    return try canonical(document)
}

/// The example's timeline records of the given `kind` (and `format`, for the two `export` records), in seq order,
/// with the entries built for them.
private func timelineRecords(kind: String, format: String? = nil) throws -> (example: [Data], built: [Data]) {
    let records = try exampleRecords()
    let entries = try timelineEntries()
    try #require(records.count == entries.count)
    var example: [Data] = [], built: [Data] = []
    for (record, entry) in zip(records, entries)
    where record["kind"] as? String == kind && (format == nil || record["format"] as? String == format) {
        example.append(try canonical(record))
        built.append(try canonical(builderBytes: ContractCoding.makeEncoder().encode(entry)))
    }
    return (example, built)
}

extension ControlContractTests {
    struct TraceExample10 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + exampleOnlyKeys))
            #expect(keys.count == 10)
            #expect(!keys.contains("actions"))
        }

        @Test func clocksSectionEqualsTheBuilderAtOneHundredTwentyBeatsPerMinute() throws {
            let built = try canonical(builderBytes: clocksRecord().encodedJSON())
            #expect(built == (try exampleSection("clocks")))
            let clocks = try #require(exampleObject()["clocks"] as? [String: Any])
            let musical = try #require(clocks["musical"] as? [String: Any])
            let map = try #require(musical["musicalMap"] as? [[String: Any]])
            #expect(map.count == 1)
            #expect(map.first?["microsPerQuarter"] as? Int == 500_000)
        }

        @Test func streamsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: streamsRecord().encodedJSON())
            #expect(built == (try exampleSection("streams")))
            let section = try #require(exampleObject()["streams"] as? [[String: Any]])
            #expect(section.map { $0["streamId"] as? String } == ["str.synth", "str.synth-legacy",
                                                                    "str.synth-unknown"])
            #expect(section.map { $0["ordinal"] as? Int } == [0, 1, 2])
        }

        @Test func initialGenerationsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
            let section = try #require(exampleObject()["initialGenerations"] as? [String: Any])
            #expect(section.count == 4)
        }

        @Test func timelineSectionEqualsTheBuilderOverTwelveEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...12))
            #expect(entries.map(\.kind) == ["anchor"] + Array(repeating: "midiCapture", count: 9)
                + ["export", "export"])
            let records = try exampleRecords()
            #expect(records.map { $0["kind"] as? String } == entries.map(\.kind))
            // The native record comes before the SMF one in this example.
            #expect(records.map { $0["format"] as? String }.suffix(2) == ["nativeUmp", "smf"])
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func midiCaptureRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "midiCapture")
            #expect(records.example.count == 9)
            #expect(records.built == records.example)
        }

        @Test func nativeExportRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "export", format: "nativeUmp")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func smfExportRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "export", format: "smf")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func theSMFRecordCountsTheEightLossCategories() throws {
            let record = try #require(timelineEntries().compactMap { entry -> SMFExportV1Record? in
                if case .smfExport(let record) = entry { record } else { nil }
            }.first)
            #expect(!record.lossless)
            #expect(record.smfFormat == 1 && record.division == 960)
            #expect(record.streams == [Fixture.synth, Fixture.legacy, Fixture.unknown])
            let named = Dictionary(uniqueKeysWithValues: record.losses.map { ($0.key.rawValue, $0.value) })
            #expect(named == ["timingQuantized": 1, "velocityDownscaled": 2, "attributeDropped": 1,
                              "perNoteDropped": 1, "valueDownscaled": 1, "noteOnVelocityRemapped": 1,
                              "fidelityUnverified": 1, "umpOnlyDropped": 1])
            #expect(record.losses.count == 8)
        }

        @Test func theTwoNotesAndTheUnverifiedFlagAppearOnlyOnSeqNineAndTen() throws {
            let captures = try exampleRecords().filter { $0["kind"] as? String == "midiCapture" }
            let noted = captures.filter { $0["note"] != nil }.map { $0["seq"] as? Int }
            #expect(noted == [9, 10])
            let unverified = captures.filter { $0["verified"] != nil }
            #expect(unverified.map { $0["seq"] as? Int } == [9])
            #expect(unverified.first?["verified"] as? Bool == false)
            #expect(unverified.first?["endpointProtocol"] as? String == "unknown")
            // The builder agrees: it writes `note` and `verified` on exactly those records.
            let built = try captureEntries(Fixture.example10()).compactMap { entry -> MIDICaptureV1Record? in
                if case .midiCapture(let record) = entry { record } else { nil }
            }
            #expect(built.filter { $0.note != nil }.map(\.seq) == [9, 10])
            #expect(built.filter { !$0.verified }.map(\.seq) == [9])
            #expect(built.first { $0.seq == 9 }?.note == unknownNote)
            #expect(built.first { $0.seq == 10 }?.note == timestampNote)
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            var fewerLosses = smfLosses
            fewerLosses[.velocityDownscaled] = 1
            let division15360: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 2, 0x3C, 0x00]
            #expect(try rebuiltDocument(losses: fewerLosses) != expected)
            #expect(try rebuiltDocument(header: division15360) != expected)
            #expect(try rebuiltDocument(originFrame: 24_001) != expected)
            #expect(try canonical(builderBytes: timelineRecord(losses: fewerLosses).encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
