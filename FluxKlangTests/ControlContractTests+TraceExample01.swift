//
//  ControlContractTests+TraceExample01.swift
//  FluxKlangTests
//
//  Media contract example 01 (#84 EXG2) rebuilt from the v1 trace builders: the `clocks`, `streams`, `actions`,
//  `initialGenerations` and `timeline` sections, each record of the timeline, and the whole document, all compared
//  with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed value;
//  nothing is decoded from the example and nothing is read from disk.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/01-clock-restart.json, whose SHA-256 is
//  2a9747506bd033ec25f8c86f5427d520e69baaf76883d1e3ca02a4ff0728b508. No builder produces the keys `contract`,
//  `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//

import Foundation
import Testing
@testable import FluxKlang

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let streamID = StreamID(validated: "str.bed")
private let actionID = ActionID(validated: "act.loop-b")
private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "streams", "initialGenerations", "actions", "timeline"]

// swiftlint:disable line_length
private let example01 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.01-clock-restart",
  "title": "Audio device restart at a new rate (48 to 96 kHz): new sample clock and transport generations; pending cue cancelled, stale cue rejected, fresh cue fires",
  "covers": ["clockRestart", "noStaleReplay", "cancellation"],
  "notes": [
    "Host timebase 125/3 ns per tick (24 MHz): 500 host ticks per frame at 48 kHz, 250 at 96 kHz.",
    "previousFrame 144000 converts at generation 1's 48 kHz to tick 92160, the last rendered position; the transport resumes there without catch-up. The transport bump may precede the clockRestart record: the resume still uses the anchor and map from before the sampleClock bump.",
    "str.bed's frame order restarts with the new generation (frame 100 after frame 120000); its streamSeq keeps increasing."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "streams": [{"streamId": "str.bed", "ordinal": 0, "media": "audio", "direction": "playback"}],
  "actions": [
    {"actionId": "act.loop-b", "media": "audio", "timePolicy": "fixedRate", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "nextBoundary"}, "notReady": "dropAndReport", "readiness": "ready", "prefetch": {"blockFrames": 4096, "blockCount": 16, "headFrames": 48000}}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "trigger", "triggerId": "trg.1", "actionId": "act.loop-b", "originHostTicks": 2460000000, "horizonFrame": 120256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "note": "Resolves to bar 3 (frame 192000); pending."},
    {"seq": 3, "kind": "dispatch", "frame": 120000, "lane": "content", "stream": "str.bed", "streamSeq": 41, "event": "bed loop block"},
    {"seq": 4, "kind": "generation", "counter": "sampleClock/smp.main", "from": 1, "to": 2, "reason": "rateChange", "nominalRate": 96000},
    {"seq": 5, "kind": "outcome", "triggerId": "trg.1", "result": "cancelled", "reason": "sampleClock", "note": "Never re-targeted onto the new clock."},
    {"seq": 6, "kind": "generation", "counter": "transport/mus.main", "from": 1, "to": 2, "reason": "clockRestart"},
    {"seq": 7, "kind": "discontinuity", "type": "clockRestart", "sampleClock": "smp.main", "generation": 2, "frame": 0, "hostTicks": 2490000000, "previousFrame": 144000},
    {"seq": 8, "kind": "anchor", "sampleClock": "smp.main", "generation": 2, "frame": 0, "hostTicks": 2490000000, "transport": 2, "musicalTicks": 92160},
    {"seq": 9, "kind": "dispatch", "frame": 100, "lane": "content", "stream": "str.bed", "streamSeq": 42, "event": "bed loop block"},
    {"seq": 10, "kind": "trigger", "triggerId": "trg.2", "actionId": "act.loop-b", "originHostTicks": 2470000000, "horizonFrame": 12512, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "note": "Pressed before the restart, delivered after it."},
    {"seq": 11, "kind": "outcome", "triggerId": "trg.2", "result": "rejectedStale", "reason": "sampleClock"},
    {"seq": 12, "kind": "trigger", "triggerId": "trg.3", "actionId": "act.loop-b", "originHostTicks": 2496000000, "horizonFrame": 24512, "requires": {"sampleClock/smp.main": 2, "transport/mus.main": 2, "context/ctx.main": 1}},
    {"seq": 13, "kind": "outcome", "triggerId": "trg.3", "result": "fired", "assignedFrame": 96000, "frame": 96000, "musicalMap": 1}]}
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
    try #require(try parse(Data(example01.utf8)) as? [String: Any])
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

private func streamsRecord() throws -> StreamsV1Record {
    try StreamsV1Record.make([StreamsV1Record.Stream(id: streamID, ordinal: 0, media: .audio, direction: .playback)])
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
    let policy = try ActionPolicy(media: .audio, timePolicy: .fixedRate, latePolicy: .nextBoundary(gridTicks: nil),
                                  gridTicks: 61_440)
    let plan = try PrefetchPlan.make(blockFrames: 4_096, blockCount: 16, headFrames: 48_000)
    let action = try ActionV1Record.make(id: actionID, policy: policy, quantize: .grid(ticks: 61_440),
                                         readiness: .ready, prefetch: plan)
    return try ActionsV1Record.make([action])
}

private func anchorEntry(_ seq: Int, generation: Generation, hostTicks: UInt64, transport: Generation,
                         ticks: Int64) throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: transport, musicalMap: .initial, ticks: ticks, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: generation, frame: 0),
                             host: HostStamp(ticks: hostTicks), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

/// A trigger of `act.loop-b` stamped under the given sample-clock and transport generations (context is 1).
private func triggerEntry(_ seq: Int, id: StaticString, originHostTicks: UInt64, horizonFrame: Int64,
                          under generation: Generation, note: String? = nil) throws -> TimelineV1Entry {
    let requires = [GenerationRequirement(key: GenerationKey(.context, ClockID(validated: "ctx.main")),
                                          generation: .initial),
                    GenerationRequirement(key: GenerationKey(.sampleClock, smpMain), generation: generation),
                    GenerationRequirement(key: GenerationKey(.transport, musMain), generation: generation)]
    let stamp = TriggerStamp(id: TriggerID(validated: id), action: actionID,
                             originHost: HostStamp(ticks: originHostTicks), horizonFrame: horizonFrame,
                             requires: requires, target: .grid(ticks: 61_440),
                             latePolicy: .nextBoundary(gridTicks: nil))
    return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: 61_440), note: note))
}

private func dispatchEntry(_ seq: Int, frame: Int64, streamSeq: UInt64) throws -> TimelineV1Entry {
    .dispatch(try DispatchV1Record.make(seq: seq, frame: frame, lane: .content, stream: streamID,
                                        streamSeq: streamSeq, event: "bed loop block"))
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

private func staleOutcome(_ seq: Int, trigger id: StaticString, result: OutcomeResult,
                          note: String? = nil) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: result,
                                 stale: .generation(GenerationKey(.sampleClock, smpMain)))
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq, note: note))
}

private func firedOutcome(_ seq: Int) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: "trg.3"), result: .fired, assignedFrame: 96_000,
                                 frame: 96_000, musicalMap: .initial)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

/// The thirteen entries of the example; `previousFrame` is the last frame rendered before the restart (seq 7).
private func timelineEntries(previousFrame: Int64 = 144_000) throws -> [TimelineV1Entry] {
    let new = try Generation(2)
    return [
        try anchorEntry(1, generation: .initial, hostTicks: 2_400_000_000, transport: .initial, ticks: 0),
        try triggerEntry(2, id: "trg.1", originHostTicks: 2_460_000_000, horizonFrame: 120_256, under: .initial,
                         note: "Resolves to bar 3 (frame 192000); pending."),
        try dispatchEntry(3, frame: 120_000, streamSeq: 41),
        try generationEntry(4, counter: GenerationKey(.sampleClock, smpMain), reason: .rateChange(nominalRate: 96_000)),
        try staleOutcome(5, trigger: "trg.1", result: .cancelled, note: "Never re-targeted onto the new clock."),
        try generationEntry(6, counter: GenerationKey(.transport, musMain), reason: .clockRestart),
        try discontinuityEntry(7, previousFrame: previousFrame),
        try anchorEntry(8, generation: new, hostTicks: 2_490_000_000, transport: new, ticks: 92_160),
        try dispatchEntry(9, frame: 100, streamSeq: 42),
        try triggerEntry(10, id: "trg.2", originHostTicks: 2_470_000_000, horizonFrame: 12_512, under: .initial,
                         note: "Pressed before the restart, delivered after it."),
        try staleOutcome(11, trigger: "trg.2", result: .rejectedStale),
        try triggerEntry(12, id: "trg.3", originHostTicks: 2_496_000_000, horizonFrame: 24_512, under: new),
        try firedOutcome(13)]
}

private func timelineRecord(previousFrame: Int64 = 144_000) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(previousFrame: previousFrame))
}

/// The whole document: the five builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(previousFrame: Int64 = 144_000) throws -> Data {
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
    document["actions"] = try parse(actionsRecord().encodedJSON())
    document["timeline"] = try parse(timelineRecord(previousFrame: previousFrame).encodedJSON())
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
    struct TraceExample01 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + exampleOnlyKeys))
            #expect(keys.count == 11)
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
            #expect(section.first?["ordinal"] as? Int == 0)
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
            #expect(try canonical(#require(action["prefetch"])) == canonical(
                ["blockFrames": 4_096, "blockCount": 16, "headFrames": 48_000]))
        }

        @Test func timelineSectionEqualsTheBuilderOverThirteenEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...13))
            #expect(entries.map(\.kind) == ["anchor", "trigger", "dispatch", "generation", "outcome", "generation",
                                            "discontinuity", "anchor", "dispatch", "trigger", "outcome", "trigger",
                                            "outcome"])
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func triggerRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "trigger")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func dispatchRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "dispatch")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func generationRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "generation")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func outcomeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "outcome")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func discontinuityRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "discontinuity")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func wholeDocumentEqualsTheFiveBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(previousFrame: 144_001) != expected)
            #expect(try canonical(builderBytes: timelineRecord(previousFrame: 144_001).encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
