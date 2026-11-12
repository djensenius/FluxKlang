//
//  ControlContractTests+TraceExample09.swift
//  FluxKlangTests
//
//  Media contract example 09 (#84 EXG5) rebuilt from the v1 trace builders: the `clocks`, `streams`,
//  `initialGenerations` and `timeline` sections, each record kind of the timeline, and the whole document, all
//  compared with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed
//  value; nothing is decoded from the example and nothing is read from disk. The comparison is semantic: it does
//  not check the key order or the number spelling of the builders' bytes.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/09-midi1-in-ump-capture-export.json, whose SHA-256 is
//  bfcf65117af9eebbf29e597c4799ca39f2439f36d35cd5f44fda6de6283d2f91. No builder produces the keys `contract`,
//  `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//
//  Limit: the example's SMF record (seq 11) says format 1 at division 960, which the real exporter does not write
//  (it writes format 0 at division 15360). It is built here from a SYNTHETIC `SMFWriteResult` (a 14-byte header and
//  typed losses), so this golden proves the RECORD BUILDER only, not that the exporter produces those losses.
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

// swiftlint:disable line_length
private let example09 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.09-midi1-in-ump-capture-export",
  "title": "MIDI 1.0 device captured as UMP: native MIDI 1 words and OS-upconverted MIDI 2 words both keep MIDI 1 fidelity",
  "covers": ["midi1InUmp", "smfExportLossless"],
  "notes": [
    "str.keys-b reads the same MIDI 1.0 endpoint through a MIDI 2.0 port: velocity 0xC924 is assumed to be the OS upscale of 100 (open question 8), not 16-bit data.",
    "Effective fidelity comes from the endpoint protocol property, never from inspecting values.",
    "At 20 BPM (9.375 frames per tick) every capture sits on division 960's 150-frame grid, so SMF export is lossless; frame 144001 would still round to tick 15360 but would be counted as timingQuantized.",
    "The device restarts before export: the native export's origin keeps generation 1's recorded anchor, so its offsets do not change."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 3000000}]}},
  "streams": [
    {"streamId": "str.keys-a", "ordinal": 0, "media": "midi", "direction": "capture"},
    {"streamId": "str.keys-b", "ordinal": 1, "media": "midi", "direction": "capture"}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "midiCapture", "stream": "str.keys-a", "ump": ["0x20903C64"], "hostTicks": 2412000000, "frame": 24000, "musicalTicks": 2560, "endpointProtocol": "midi1", "portProtocol": "midi1", "translatedBy": "none", "effective": "midi1"},
    {"seq": 3, "kind": "midiCapture", "stream": "str.keys-a", "ump": ["0x20803C00"], "hostTicks": 2424000000, "frame": 48000, "musicalTicks": 5120, "endpointProtocol": "midi1", "portProtocol": "midi1", "translatedBy": "none", "effective": "midi1"},
    {"seq": 4, "kind": "midiCapture", "stream": "str.keys-b", "ump": ["0x40903C00", "0xC9240000"], "hostTicks": 2436000000, "frame": 72000, "musicalTicks": 7680, "endpointProtocol": "midi1", "portProtocol": "midi2", "translatedBy": "os", "effective": "midi1"},
    {"seq": 5, "kind": "midiCapture", "stream": "str.keys-b", "ump": ["0x40B00700", "0x80000000"], "hostTicks": 2442000000, "frame": 84000, "musicalTicks": 8960, "endpointProtocol": "midi1", "portProtocol": "midi2", "translatedBy": "os", "effective": "midi1"},
    {"seq": 6, "kind": "midiCapture", "stream": "str.keys-b", "ump": ["0x40803C00", "0x00000000"], "hostTicks": 2472000000, "frame": 144000, "musicalTicks": 15360, "endpointProtocol": "midi1", "portProtocol": "midi2", "translatedBy": "os", "effective": "midi1"},
    {"seq": 7, "kind": "generation", "counter": "sampleClock/smp.main", "from": 1, "to": 2, "reason": "deviceRestart"},
    {"seq": 8, "kind": "discontinuity", "type": "clockRestart", "sampleClock": "smp.main", "generation": 2, "frame": 0, "hostTicks": 2490000000, "previousFrame": 150000},
    {"seq": 9, "kind": "generation", "counter": "transport/mus.main", "from": 1, "to": 2, "reason": "clockRestart"},
    {"seq": 10, "kind": "anchor", "sampleClock": "smp.main", "generation": 2, "frame": 0, "hostTicks": 2490000000, "transport": 2, "musicalTicks": 16000},
    {"seq": 11, "kind": "export", "exportId": "exp.smf", "streams": ["str.keys-a", "str.keys-b"], "format": "smf", "smfFormat": 1, "division": 960, "lossless": true, "losses": {}},
    {"seq": 12, "kind": "export", "exportId": "exp.ump", "streams": ["str.keys-a", "str.keys-b"], "format": "nativeUmp", "origin": {"sampleClock": "smp.main", "generation": 1, "frame": 0}, "offsetsNs": [500000000, 1000000000, 1500000000, 1750000000, 3000000000], "lossless": true, "losses": {}}]}
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
    try #require(try parse(Data(example09.utf8)) as? [String: Any])
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
        segments: [TempoSegment(.init(atTicks: 0, microsPerQuarter: 3_000_000), unknownFields: [:])],
        meter: MusicalMeter(.init(numerator: 4, denominator: 4)), loop: nil)
    let transport = try TransportDocument(revision: .initial, payload: ControlRecord(fields))
    return try ClocksV1Record.make(transport: transport, timebase: HostTimebase(numer: 125, denom: 3))
}

private func streamsRecord() throws -> StreamsV1Record {
    try StreamsV1Record.make([
        StreamsV1Record.Stream(id: Fixture.keysA, ordinal: 0, media: .midi, direction: .capture),
        StreamsV1Record.Stream(id: Fixture.keysB, ordinal: 1, media: .midi, direction: .capture)])
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

private func anchorEntry(_ seq: Int, generation: Generation, hostTicks: UInt64, transport: Generation,
                         ticks: Int64) throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: transport, musicalMap: .initial, ticks: ticks, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: generation, frame: 0),
                             host: HostStamp(ticks: hostTicks), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

private func generationEntry(_ seq: Int, counter: GenerationKey,
                             reason: GenerationBumpReason) throws -> TimelineV1Entry {
    let next = try Generation(2)
    return .generation(try GenerationV1Record.make(counter: counter, from: .initial, to: next, reason: reason,
                                                   seq: seq))
}

private func discontinuityEntry(_ seq: Int, previousFrame: Int64) throws -> TimelineV1Entry {
    let event = DiscontinuityV1Record.Event.clockRestart(hostTicks: 2_490_000_000, previousFrame: previousFrame)
    return .discontinuity(try DiscontinuityV1Record.make(event, sampleClock: smpMain, generation: Generation(2),
                                                         frame: 0, seq: seq))
}

/// The capture log of example 09 after the device restart of seq 8 and 10, and the five captures it holds.
private func restartedLog() throws -> MIDICaptureLog {
    var log = try Fixture.example09Captures()
    try Fixture.restartExample09(&log)
    return log
}

private func captureEntries(_ log: MIDICaptureLog) throws -> [TimelineV1Entry] {
    try log.records.enumerated().map { index, record in
        .midiCapture(try MIDICaptureV1Record.make(record, seq: index + 2))
    }
}

/// seq 11: a synthetic format 1 file at division 960 with no losses; the real exporter writes neither.
private func smfEntry(header: [UInt8]) throws -> TimelineV1Entry {
    let file = SMFWriteResult(bytes: header, losses: SMFExportLossReport(losses: [:]), reorderedItems: 0)
    return .smfExport(try SMFExportV1Record.make(file, streams: [Fixture.keysA, Fixture.keysB],
                                                 exportID: ExportID(validated: "exp.smf"), seq: 11))
}

/// seq 12: the native export over both streams, anchored at generation 1 frame 0.
private func nativeEntry(_ log: MIDICaptureLog) throws -> TimelineV1Entry {
    let export = try NativeUMPExport.make(from: log, id: Fixture.umpExport, streams: [Fixture.keysA, Fixture.keysB],
                                          origin: Fixture.origin(1, frame: 0))
    return .export(try NativeUMPExportV1Record.make(export, seq: 12))
}

/// The twelve entries of the example; `previousFrame` is the last frame rendered before the restart (seq 8).
private func timelineEntries(previousFrame: Int64 = 150_000,
                             header: [UInt8] = smfHeader) throws -> [TimelineV1Entry] {
    let log = try restartedLog()
    let new = try Generation(2)
    return try [try anchorEntry(1, generation: .initial, hostTicks: 2_400_000_000, transport: .initial, ticks: 0)]
        + captureEntries(log) + [
            try generationEntry(7, counter: GenerationKey(.sampleClock, smpMain), reason: .deviceRestart),
            try discontinuityEntry(8, previousFrame: previousFrame),
            try generationEntry(9, counter: GenerationKey(.transport, musMain), reason: .clockRestart),
            try anchorEntry(10, generation: new, hostTicks: 2_490_000_000, transport: new, ticks: 16_000),
            try smfEntry(header: header),
            try nativeEntry(log)]
}

private func timelineRecord(previousFrame: Int64 = 150_000, header: [UInt8] = smfHeader) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(previousFrame: previousFrame, header: header))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(previousFrame: Int64 = 150_000, header: [UInt8] = smfHeader) throws -> Data {
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
    document["timeline"] = try parse(timelineRecord(previousFrame: previousFrame, header: header).encodedJSON())
    return try canonical(document)
}

/// The example's timeline records of the given `kind` (and `format`, for the two `export` records), in seq order,
/// with the entries built for them.
private func timelineRecords(kind: String, format: String? = nil) throws -> (example: [Data], built: [Data]) {
    let records = try #require(exampleObject()["timeline"] as? [[String: Any]])
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
    struct TraceExample09 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + exampleOnlyKeys))
            #expect(keys.count == 10)
            #expect(!keys.contains("actions"))
        }

        @Test func clocksSectionEqualsTheBuilderAtTwentyBeatsPerMinute() throws {
            let built = try canonical(builderBytes: clocksRecord().encodedJSON())
            #expect(built == (try exampleSection("clocks")))
            let clocks = try #require(exampleObject()["clocks"] as? [String: Any])
            let musical = try #require(clocks["musical"] as? [String: Any])
            let map = try #require(musical["musicalMap"] as? [[String: Any]])
            #expect(map.count == 1)
            #expect(map.first?["microsPerQuarter"] as? Int == 3_000_000)
        }

        @Test func streamsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: streamsRecord().encodedJSON())
            #expect(built == (try exampleSection("streams")))
            let section = try #require(exampleObject()["streams"] as? [[String: Any]])
            #expect(section.map { $0["streamId"] as? String } == ["str.keys-a", "str.keys-b"])
            #expect(section.map { $0["ordinal"] as? Int } == [0, 1])
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
            #expect(entries.map(\.kind) == ["anchor", "midiCapture", "midiCapture", "midiCapture", "midiCapture",
                                            "midiCapture", "generation", "discontinuity", "generation", "anchor",
                                            "export", "export"])
            let records = try #require(exampleObject()["timeline"] as? [[String: Any]])
            #expect(records.map { $0["kind"] as? String } == entries.map(\.kind))
            // The SMF record comes before the native one in this example.
            #expect(records.map { $0["format"] as? String }.suffix(2) == ["smf", "nativeUmp"])
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func midiCaptureRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "midiCapture")
            #expect(records.example.count == 5)
            #expect(records.built == records.example)
        }

        @Test func generationRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "generation")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func discontinuityRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "discontinuity")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func smfExportRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "export", format: "smf")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func nativeExportRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "export", format: "nativeUmp")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func theSMFRecordIsLosslessWithNoLossesAndBothStreamsInOrder() throws {
            let record = try #require(timelineEntries().compactMap { entry -> SMFExportV1Record? in
                if case .smfExport(let record) = entry { record } else { nil }
            }.first)
            #expect(record.lossless)
            #expect(record.losses.isEmpty)
            #expect(record.smfFormat == 1 && record.division == 960)
            #expect(record.streams == [Fixture.keysA, Fixture.keysB])
            // The two streams carry the word counts of the example's keys-a and keys-b records.
            let log = try restartedLog()
            let counts = Dictionary(grouping: log.records, by: \.stream).mapValues { $0.map(\.packet.words.count) }
            #expect(counts[Fixture.keysA] == [1, 1])
            #expect(counts[Fixture.keysB] == [2, 2, 2])
            let captures = try #require(exampleObject()["timeline"] as? [[String: Any]])
                .filter { $0["kind"] as? String == "midiCapture" }
            let exampleCounts = Dictionary(grouping: captures, by: { $0["stream"] as? String ?? "" })
                .mapValues { $0.map { ($0["ump"] as? [String])?.count ?? 0 } }
            #expect(exampleCounts == ["str.keys-a": [1, 1], "str.keys-b": [2, 2, 2]])
        }

        @Test func theRestartIsExactlyTheFourRecordsOfSeqSevenToTen() throws {
            let entries = try timelineEntries()
            try #require(entries.count == 12)
            let restart = Array(entries[6...9])
            #expect(restart.map(\.seq) == [7, 8, 9, 10])
            #expect(restart.map(\.kind) == ["generation", "discontinuity", "generation", "anchor"])
            let built = try restart.map { try canonical(builderBytes: ContractCoding.makeEncoder().encode($0)) }
            let records = try #require(exampleObject()["timeline"] as? [[String: Any]])
            try #require(records.count == 12)
            #expect(try records[6...9].map { try canonical($0) } == built)
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            // The kind tests name which record differs; this one also catches a key a builder adds or drops.
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            let format0: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x03, 0xC0]
            let division15360: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 2, 0x3C, 0x00]
            #expect(try rebuiltDocument(header: format0) != expected)
            #expect(try rebuiltDocument(header: division15360) != expected)
            #expect(try rebuiltDocument(previousFrame: 150_001) != expected)
            #expect(try canonical(builderBytes: timelineRecord(previousFrame: 150_001).encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
