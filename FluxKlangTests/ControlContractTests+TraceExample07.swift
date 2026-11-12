//
//  ControlContractTests+TraceExample07.swift
//  FluxKlangTests
//
//  Media contract example 07 (#84 EXG1) rebuilt from the v1 trace builders: the `clocks`, `initialGenerations`,
//  `actions` and `timeline` sections, each record of the timeline, and the whole document, all compared with a
//  copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed value; nothing is
//  decoded from the example and nothing is read from disk.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/07-readiness-and-prefetch.json, whose SHA-256 is
//  4b70de10db275367f67c1b91ec16c96b562737b853ffa62a1f4c54cd2d031454. No builder produces the keys `contract`,
//  `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//

import Foundation
import Testing
@testable import FluxKlang

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let actionID = ActionID(validated: "act.intro")
private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "initialGenerations", "actions", "timeline"]

// swiftlint:disable line_length
private let example07 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.07-readiness-and-prefetch",
  "title": "Readiness: unprepared and invalidated actions drop and report; nothing loads at fire time",
  "covers": ["readiness", "prefetch"],
  "notes": [
    "Ready means the bounded prefetch head (48000 frames in 16 x 4096-frame pool blocks) is resident.",
    "Armed is a derived UI state (ready plus a pending trigger), not a readiness state."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "actions": [
    {"actionId": "act.intro", "media": "audio", "timePolicy": "fixedRate", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "drop"}, "notReady": "dropAndReport", "readiness": "unprepared", "prefetch": {"blockFrames": 4096, "blockCount": 16, "headFrames": 48000}}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "trigger", "triggerId": "trg.1", "actionId": "act.intro", "originHostTicks": 2400500000, "horizonFrame": 1256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}},
    {"seq": 3, "kind": "outcome", "triggerId": "trg.1", "result": "dropped", "reason": "notReady"},
    {"seq": 4, "kind": "readiness", "actionId": "act.intro", "from": "unprepared", "to": "preparing"},
    {"seq": 5, "kind": "readiness", "actionId": "act.intro", "from": "preparing", "to": "ready"},
    {"seq": 6, "kind": "trigger", "triggerId": "trg.2", "actionId": "act.intro", "originHostTicks": 2415000000, "horizonFrame": 30256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}},
    {"seq": 7, "kind": "outcome", "triggerId": "trg.2", "result": "fired", "assignedFrame": 96000, "frame": 96000, "musicalMap": 1},
    {"seq": 8, "kind": "readiness", "actionId": "act.intro", "from": "ready", "to": "invalidated", "reason": "memoryPressure"},
    {"seq": 9, "kind": "trigger", "triggerId": "trg.3", "actionId": "act.intro", "originHostTicks": 2465000000, "horizonFrame": 130256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}},
    {"seq": 10, "kind": "outcome", "triggerId": "trg.3", "result": "dropped", "reason": "notReady"},
    {"seq": 11, "kind": "readiness", "actionId": "act.intro", "from": "invalidated", "to": "preparing"},
    {"seq": 12, "kind": "readiness", "actionId": "act.intro", "from": "preparing", "to": "failed", "reason": "assetChanged"}]}
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
    try #require(try parse(Data(example07.utf8)) as? [String: Any])
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

private func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, smpMain): .initial,
        GenerationKey(.transport, musMain): .initial,
        GenerationKey(.musicalMap, musMain): .initial,
        GenerationKey(.context, ClockID(validated: "ctx.main")): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

private func actionsRecord() throws -> ActionsV1Record {
    let policy = try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .drop, gridTicks: 61_440)
    let plan = try PrefetchPlan.make(blockFrames: 4_096, blockCount: 16, headFrames: 48_000)
    let action = try ActionV1Record.make(id: actionID, policy: policy, quantize: .grid(ticks: 61_440),
                                         readiness: .unprepared, prefetch: plan)
    return try ActionsV1Record.make([action])
}

private func anchorEntry(_ seq: Int) throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: 0),
                             host: HostStamp(ticks: 2_400_000_000), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

private func triggerEntry(_ seq: Int, id: StaticString, originHostTicks: UInt64,
                          horizonFrame: Int64) throws -> TimelineV1Entry {
    let requires = [GenerationRequirement(key: GenerationKey(.context, ClockID(validated: "ctx.main")),
                                          generation: .initial),
                    GenerationRequirement(key: GenerationKey(.sampleClock, smpMain), generation: .initial),
                    GenerationRequirement(key: GenerationKey(.transport, musMain), generation: .initial)]
    let stamp = TriggerStamp(id: TriggerID(validated: id), action: actionID,
                             originHost: HostStamp(ticks: originHostTicks), horizonFrame: horizonFrame,
                             requires: requires, target: .grid(ticks: 61_440), latePolicy: .drop)
    return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: 61_440)))
}

private func droppedNotReady(_ seq: Int, trigger id: StaticString) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: .dropped, reason: .notReady)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

private func firedOutcome(_ seq: Int) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: "trg.2"), result: .fired, assignedFrame: 96_000,
                                 frame: 96_000, musicalMap: .initial)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

private func readinessEntry(_ seq: Int, from: ReadinessState, to: ReadinessState,
                            reason: String? = nil) throws -> TimelineV1Entry {
    .readiness(try ReadinessV1Record.make(actionID, from: from, to: to, seq: seq, reason: reason))
}

/// The twelve entries of the example; `invalidationReason` is the reason of seq 8.
private func timelineEntries(invalidationReason: String = "memoryPressure") throws -> [TimelineV1Entry] {
    [try anchorEntry(1),
     try triggerEntry(2, id: "trg.1", originHostTicks: 2_400_500_000, horizonFrame: 1_256),
     try droppedNotReady(3, trigger: "trg.1"),
     try readinessEntry(4, from: .unprepared, to: .preparing),
     try readinessEntry(5, from: .preparing, to: .ready),
     try triggerEntry(6, id: "trg.2", originHostTicks: 2_415_000_000, horizonFrame: 30_256),
     try firedOutcome(7),
     try readinessEntry(8, from: .ready, to: .invalidated, reason: invalidationReason),
     try triggerEntry(9, id: "trg.3", originHostTicks: 2_465_000_000, horizonFrame: 130_256),
     try droppedNotReady(10, trigger: "trg.3"),
     try readinessEntry(11, from: .invalidated, to: .preparing),
     try readinessEntry(12, from: .preparing, to: .failed, reason: "assetChanged")]
}

private func timelineRecord(invalidationReason: String = "memoryPressure") throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(invalidationReason: invalidationReason))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(invalidationReason: String = "memoryPressure") throws -> Data {
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
    document["initialGenerations"] = try parse(initialGenerationsRecord().encodedJSON())
    document["actions"] = try parse(actionsRecord().encodedJSON())
    document["timeline"] = try parse(timelineRecord(invalidationReason: invalidationReason).encodedJSON())
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
    struct TraceExample07 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + exampleOnlyKeys))
            #expect(keys.count == 10)
        }

        @Test func clocksSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: clocksRecord().encodedJSON())
            #expect(built == (try exampleSection("clocks")))
        }

        @Test func initialGenerationsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
            let section = try #require(exampleObject()["initialGenerations"] as? [String: Any])
            #expect(section.count == 4)
        }

        @Test func actionsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: actionsRecord().encodedJSON())
            #expect(built == (try exampleSection("actions")))
            let section = try #require(exampleObject()["actions"] as? [[String: Any]])
            let action = try #require(section.first)
            #expect(section.count == 1)
            #expect(action["notReady"] as? String == "dropAndReport")
            #expect(try canonical(#require(action["prefetch"])) == canonical(
                ["blockFrames": 4_096, "blockCount": 16, "headFrames": 48_000]))
        }

        @Test func timelineSectionEqualsTheBuilderOverTwelveEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...12))
            #expect(entries.map(\.kind) == ["anchor", "trigger", "outcome", "readiness", "readiness", "trigger",
                                            "outcome", "readiness", "trigger", "outcome", "readiness",
                                            "readiness"])
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func triggerRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "trigger")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func outcomeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "outcome")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func readinessRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "readiness")
            #expect(records.example.count == 5)
            #expect(records.built == records.example)
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(invalidationReason: "other") != expected)
            #expect(try canonical(builderBytes: timelineRecord(invalidationReason: "other").encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
