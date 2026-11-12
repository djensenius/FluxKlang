//
//  ControlContractTests+TraceExample05.swift
//  FluxKlangTests
//
//  Media contract example 05 (#84 EXG3) rebuilt from the v1 trace builders: the `clocks`, `streams`, `actions`,
//  `initialGenerations` and `timeline` sections, each record kind of the timeline, and the whole document, all
//  compared with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed
//  value; nothing is decoded from the example and nothing is read from disk.
//
//  The literal below is a verbatim copy of docs/transformation/media-contract/examples/05-source-loss.json,
//  whose SHA-256 is d1db675d0b2f0ba70cefbbf1b856ca452c38cb67e03396ed388709d996f107ef. No builder produces the
//  keys `contract`, `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//

import Foundation
import Testing
@testable import FluxKlang

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let backingStream = StreamID(validated: "str.backing")
private let backingAction = ActionID(validated: "act.backing")
private let sourceKey = GenerationKey(.source, GenerationSubject(validated: "src.backing"))
private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "streams", "actions", "initialGenerations", "timeline"]

// swiftlint:disable line_length
private let example05 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.05-source-loss",
  "title": "Source loss and reacquisition: prefetch underrun, pending cue cancelled, stale cue rejected after recovery, fresh cue fires",
  "covers": ["sourceLoss", "noStaleReplay", "prefetch", "cancellation"],
  "notes": [
    "An underrun outputs silence and skips the missing source frames so the voice stays aligned.",
    "Reacquiring the source is a new source generation; triggers stamped before the loss never replay."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "streams": [{"streamId": "str.backing", "ordinal": 0, "media": "audio", "direction": "playback"}],
  "actions": [
    {"actionId": "act.backing", "media": "audio", "timePolicy": "fixedRate", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "joinInProgress", "maxLatenessMs": 50}, "notReady": "dropAndReport", "readiness": "ready", "prefetch": {"blockFrames": 4096, "blockCount": 16, "headFrames": 48000}}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1,
    "source/src.backing": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "trigger", "triggerId": "trg.1", "actionId": "act.backing", "originHostTicks": 2400500000, "horizonFrame": 1256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1, "source/src.backing": 1}},
    {"seq": 3, "kind": "outcome", "triggerId": "trg.1", "result": "fired", "assignedFrame": 96000, "frame": 96000, "musicalMap": 1},
    {"seq": 4, "kind": "discontinuity", "type": "underrun", "sampleClock": "smp.main", "generation": 1, "frame": 150000, "frames": 512, "stream": "str.backing"},
    {"seq": 5, "kind": "trigger", "triggerId": "trg.2", "actionId": "act.backing", "originHostTicks": 2485000000, "horizonFrame": 170256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1, "source/src.backing": 1}, "note": "Resolves to frame 192000; pending."},
    {"seq": 6, "kind": "generation", "counter": "source/src.backing", "from": 1, "to": 2, "reason": "sourceLost"},
    {"seq": 7, "kind": "discontinuity", "type": "sourceLost", "sampleClock": "smp.main", "generation": 1, "frame": 180000, "stream": "str.backing", "note": "volume unmounted"},
    {"seq": 8, "kind": "readiness", "actionId": "act.backing", "from": "ready", "to": "invalidated", "reason": "sourceLost"},
    {"seq": 9, "kind": "outcome", "triggerId": "trg.2", "result": "cancelled", "reason": "source"},
    {"seq": 10, "kind": "generation", "counter": "source/src.backing", "from": 2, "to": 3, "reason": "sourceReacquired"},
    {"seq": 11, "kind": "discontinuity", "type": "sourceRestored", "sampleClock": "smp.main", "generation": 1, "frame": 230000, "stream": "str.backing"},
    {"seq": 12, "kind": "readiness", "actionId": "act.backing", "from": "invalidated", "to": "preparing"},
    {"seq": 13, "kind": "readiness", "actionId": "act.backing", "from": "preparing", "to": "ready"},
    {"seq": 14, "kind": "trigger", "triggerId": "trg.3", "actionId": "act.backing", "originHostTicks": 2487500000, "horizonFrame": 235256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1, "source/src.backing": 1}, "note": "Queued before the loss and delivered after recovery."},
    {"seq": 15, "kind": "outcome", "triggerId": "trg.3", "result": "rejectedStale", "reason": "source"},
    {"seq": 16, "kind": "trigger", "triggerId": "trg.4", "actionId": "act.backing", "originHostTicks": 2520000000, "horizonFrame": 240256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1, "source/src.backing": 3}},
    {"seq": 17, "kind": "outcome", "triggerId": "trg.4", "result": "fired", "assignedFrame": 288000, "frame": 288000, "musicalMap": 1}]}
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
    try #require(try parse(Data(example05.utf8)) as? [String: Any])
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
    try StreamsV1Record.make([.init(id: backingStream, ordinal: 0, media: .audio, direction: .playback)])
}

private func actionsRecord(maxLatenessMs: Int = 50) throws -> ActionsV1Record {
    let policy = try ActionPolicy(media: .audio, timePolicy: .fixedRate,
                                  latePolicy: .joinInProgress(maxLatenessMs: maxLatenessMs), gridTicks: 61_440)
    let plan = try PrefetchPlan.make(blockFrames: 4_096, blockCount: 16, headFrames: 48_000)
    let action = try ActionV1Record.make(id: backingAction, policy: policy, quantize: .grid(ticks: 61_440),
                                         readiness: .ready, prefetch: plan)
    return try ActionsV1Record.make([action])
}

private func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, smpMain): .initial,
        GenerationKey(.transport, musMain): .initial,
        GenerationKey(.musicalMap, musMain): .initial,
        GenerationKey(.context, ClockID(validated: "ctx.main")): .initial,
        sourceKey: .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

private func anchorEntry(_ seq: Int) throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: 0),
                             host: HostStamp(ticks: 2_400_000_000), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

private func triggerEntry(_ seq: Int, id: StaticString, originHostTicks: UInt64, horizonFrame: Int64,
                          source: Generation, note: String? = nil) throws -> TimelineV1Entry {
    let requires = [GenerationRequirement(key: GenerationKey(.context, ClockID(validated: "ctx.main")),
                                          generation: .initial),
                    GenerationRequirement(key: GenerationKey(.sampleClock, smpMain), generation: .initial),
                    GenerationRequirement(key: sourceKey, generation: source),
                    GenerationRequirement(key: GenerationKey(.transport, musMain), generation: .initial)]
    let stamp = TriggerStamp(id: TriggerID(validated: id), action: backingAction,
                             originHost: HostStamp(ticks: originHostTicks), horizonFrame: horizonFrame,
                             requires: requires, target: .grid(ticks: 61_440),
                             latePolicy: .joinInProgress(maxLatenessMs: 50))
    return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: 61_440), note: note))
}

private func firedEntry(_ seq: Int, trigger id: StaticString, frame: Int64) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: .fired, assignedFrame: frame,
                                 frame: frame, musicalMap: .initial)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

/// A `cancelled` or `rejectedStale` outcome whose reason (`source`) the record derives from the counter's kind.
private func staleEntry(_ seq: Int, trigger id: StaticString, _ result: OutcomeResult) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: result, stale: .generation(sourceKey))
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

private func discontinuityEntry(_ seq: Int, _ event: DiscontinuityV1Record.Event, frame: Int64,
                                note: String? = nil) throws -> TimelineV1Entry {
    .discontinuity(try DiscontinuityV1Record.make(event, sampleClock: smpMain, generation: .initial, frame: frame,
                                                  seq: seq, note: note))
}

private func generationEntry(_ seq: Int, from: Int, to: Int,
                             reason: GenerationBumpReason) throws -> TimelineV1Entry {
    .generation(try GenerationV1Record.make(counter: sourceKey, from: Generation(from), to: Generation(to),
                                            reason: reason, seq: seq))
}

private func readinessEntry(_ seq: Int, from: ReadinessState, to: ReadinessState,
                            reason: String? = nil) throws -> TimelineV1Entry {
    .readiness(try ReadinessV1Record.make(backingAction, from: from, to: to, seq: seq, reason: reason))
}

/// The seventeen entries of the example; `lostReason` is the reason of seq 8.
private func timelineEntries(lostReason: String = "sourceLost") throws -> [TimelineV1Entry] {
    let loss = "volume unmounted"
    return [
        try anchorEntry(1),
        try triggerEntry(2, id: "trg.1", originHostTicks: 2_400_500_000, horizonFrame: 1_256, source: .initial),
        try firedEntry(3, trigger: "trg.1", frame: 96_000),
        try discontinuityEntry(4, .underrun(backingStream, frames: 512), frame: 150_000),
        try triggerEntry(5, id: "trg.2", originHostTicks: 2_485_000_000, horizonFrame: 170_256, source: .initial,
                         note: "Resolves to frame 192000; pending."),
        try generationEntry(6, from: 1, to: 2, reason: .sourceLost),
        try discontinuityEntry(7, .sourceLost(backingStream), frame: 180_000, note: loss),
        try readinessEntry(8, from: .ready, to: .invalidated, reason: lostReason),
        try staleEntry(9, trigger: "trg.2", .cancelled),
        try generationEntry(10, from: 2, to: 3, reason: .sourceReacquired),
        try discontinuityEntry(11, .sourceRestored(backingStream), frame: 230_000),
        try readinessEntry(12, from: .invalidated, to: .preparing),
        try readinessEntry(13, from: .preparing, to: .ready),
        try triggerEntry(14, id: "trg.3", originHostTicks: 2_487_500_000, horizonFrame: 235_256, source: .initial,
                         note: "Queued before the loss and delivered after recovery."),
        try staleEntry(15, trigger: "trg.3", .rejectedStale),
        try triggerEntry(16, id: "trg.4", originHostTicks: 2_520_000_000, horizonFrame: 240_256,
                         source: Generation(3)),
        try firedEntry(17, trigger: "trg.4", frame: 288_000)
    ]
}

private func timelineRecord(lostReason: String = "sourceLost") throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(lostReason: lostReason))
}

/// The whole document: the five builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(lostReason: String = "sourceLost") throws -> Data {
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
    document["actions"] = try parse(actionsRecord().encodedJSON())
    document["initialGenerations"] = try parse(initialGenerationsRecord().encodedJSON())
    document["timeline"] = try parse(timelineRecord(lostReason: lostReason).encodedJSON())
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
    struct TraceExample05 {
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
            #expect(section.first?["direction"] as? String == "playback")
        }

        @Test func actionsSectionEqualsTheBuilderAndCarriesTheJoinWindow() throws {
            let built = try canonical(builderBytes: actionsRecord().encodedJSON())
            #expect(built == (try exampleSection("actions")))
            let section = try #require(exampleObject()["actions"] as? [[String: Any]])
            let action = try #require(section.first)
            #expect(section.count == 1)
            #expect(action["readiness"] as? String == "ready")
            let late = try #require(action["late"] as? [String: Any])
            #expect(late["policy"] as? String == "joinInProgress")
            #expect(late["maxLatenessMs"] as? Int == 50)
            #expect(try canonical(builderBytes: actionsRecord(maxLatenessMs: 51).encodedJSON())
                != (try exampleSection("actions")))
        }

        @Test func initialGenerationsSectionHasFiveCountersIncludingTheSource() throws {
            let built = try canonical(builderBytes: initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
            let section = try #require(exampleObject()["initialGenerations"] as? [String: Any])
            #expect(section.count == 5)
            #expect(section["source/src.backing"] as? Int == 1)
        }

        @Test func timelineSectionEqualsTheBuilderOverSeventeenEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...17))
            #expect(entries.map(\.kind) == [
                "anchor", "trigger", "outcome", "discontinuity", "trigger", "generation", "discontinuity",
                "readiness", "outcome", "generation", "discontinuity", "readiness", "readiness", "trigger",
                "outcome", "trigger", "outcome"])
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
            #expect(records.example.count == 4)
            #expect(records.built == records.example)
        }

        @Test func outcomeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "outcome")
            #expect(records.example.count == 4)
            #expect(records.built == records.example)
        }

        @Test func generationRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "generation")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func readinessRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "readiness")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func discontinuityRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "discontinuity")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func wholeDocumentEqualsTheFiveBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(lostReason: "other") != expected)
            #expect(try canonical(builderBytes: timelineRecord(lostReason: "other").encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
