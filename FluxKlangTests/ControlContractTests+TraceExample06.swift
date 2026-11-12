//
//  ControlContractTests+TraceExample06.swift
//  FluxKlangTests
//
//  Media contract example 06 (#84 EXG2) rebuilt from the v1 trace builders: the `clocks`, `actions`,
//  `initialGenerations` and `timeline` sections, each record of the timeline, and the whole document, all compared
//  with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed value;
//  nothing is decoded from the example and nothing is read from disk.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/06-stale-trigger-no-replay.json, whose SHA-256 is
//  a7d3d4f9e767f59d8aba4a7c2763d13f16db3cec535829ce449b86bcb551192b. No builder produces the keys `contract`,
//  `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//

import Foundation
import Testing
@testable import FluxKlang

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let ctxMain = ClockID(validated: "ctx.main")
private let setVerse = ClockID(validated: "set.verse")
private let clipID = ActionID(validated: "act.clip")
private let sceneID = ActionID(validated: "act.scene")
private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "initialGenerations", "actions", "timeline"]

// swiftlint:disable line_length
private let example06 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.06-stale-trigger-no-replay",
  "title": "User cancel and context change: pending cues cancelled; an old-context trigger is rejected, never replayed",
  "covers": ["noStaleReplay", "cancellation"],
  "notes": [
    "Every trigger receives exactly one terminal outcome; cancelled and rejected triggers need a fresh trigger to act."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "actions": [
    {"actionId": "act.clip", "media": "midi", "timePolicy": "tempoFollowing", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "nextBoundary"}, "notReady": "dropAndReport", "readiness": "ready"},
    {"actionId": "act.scene", "media": "state", "quantize": {"timeBase": "musical", "gridTicks": 15360}, "late": {"policy": "nextBoundary"}, "notReady": "dropAndReport", "readiness": "ready"}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1,
    "cancelScope/set.verse": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "trigger", "triggerId": "trg.1", "actionId": "act.clip", "originHostTicks": 2405000000, "horizonFrame": 10256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1, "cancelScope/set.verse": 1}},
    {"seq": 3, "kind": "trigger", "triggerId": "trg.2", "actionId": "act.scene", "originHostTicks": 2406000000, "horizonFrame": 12256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1, "cancelScope/set.verse": 1}},
    {"seq": 4, "kind": "generation", "counter": "cancelScope/set.verse", "from": 1, "to": 2, "reason": "userCancel"},
    {"seq": 5, "kind": "outcome", "triggerId": "trg.1", "result": "cancelled", "reason": "cancelScope"},
    {"seq": 6, "kind": "outcome", "triggerId": "trg.2", "result": "cancelled", "reason": "cancelScope"},
    {"seq": 7, "kind": "generation", "counter": "context/ctx.main", "from": 1, "to": 2, "reason": "contextChange"},
    {"seq": 8, "kind": "trigger", "triggerId": "trg.3", "actionId": "act.clip", "originHostTicks": 2405000000, "horizonFrame": 20256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1, "cancelScope/set.verse": 1}, "note": "A retry of trg.1 with its original stamps."},
    {"seq": 9, "kind": "outcome", "triggerId": "trg.3", "result": "rejectedStale", "reason": "context"},
    {"seq": 10, "kind": "trigger", "triggerId": "trg.4", "actionId": "act.clip", "originHostTicks": 2410000000, "horizonFrame": 20256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 2, "cancelScope/set.verse": 2}},
    {"seq": 11, "kind": "outcome", "triggerId": "trg.4", "result": "fired", "assignedFrame": 96000, "frame": 96000, "musicalMap": 1}]}
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
    try #require(try parse(Data(example06.utf8)) as? [String: Any])
}

/// One section of the example, in canonical form.
private func exampleSection(_ key: String) throws -> Data {
    try canonical(#require(exampleObject()[key], "\(key)"))
}

// MARK: - Builder inputs

private func generation(_ value: Int) throws -> Generation {
    try Generation(value)
}

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
        GenerationKey(.context, ctxMain): .initial,
        GenerationKey(.cancelScope, setVerse): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

private func clipPolicy() throws -> ActionPolicy {
    try ActionPolicy(media: .midi, timePolicy: .tempoFollowing, latePolicy: .nextBoundary(gridTicks: nil),
                     gridTicks: 61_440)
}

private func scenePolicy() throws -> ActionPolicy {
    try ActionPolicy(media: .state, timePolicy: nil, latePolicy: .nextBoundary(gridTicks: nil), gridTicks: 15_360)
}

private func actionsRecord() throws -> ActionsV1Record {
    let clip = try ActionV1Record.make(id: clipID, policy: clipPolicy(), quantize: .grid(ticks: 61_440),
                                       readiness: .ready)
    let scene = try ActionV1Record.make(id: sceneID, policy: scenePolicy(), quantize: .grid(ticks: 15_360),
                                        readiness: .ready)
    return try ActionsV1Record.make([clip, scene])
}

private func anchorEntry(_ seq: Int) throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: 0),
                             host: HostStamp(ticks: 2_400_000_000), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

/// What a trigger names: its ID, its action, its origin and its horizon.
private struct Press {
    let id: StaticString
    let action: ActionID
    let originHostTicks: UInt64
    let horizonFrame: Int64
}

/// A trigger of `act.clip` or `act.scene`, stamped under the given context and cancel-scope generations.
private func triggerEntry(_ seq: Int, _ press: Press, context: Int, cancelScope: Int,
                          note: String? = nil) throws -> TimelineV1Entry {
    let requires = [GenerationRequirement(key: GenerationKey(.cancelScope, setVerse),
                                          generation: try generation(cancelScope)),
                    GenerationRequirement(key: GenerationKey(.context, ctxMain), generation: try generation(context)),
                    GenerationRequirement(key: GenerationKey(.sampleClock, smpMain), generation: .initial),
                    GenerationRequirement(key: GenerationKey(.transport, musMain), generation: .initial)]
    let grid: Int64 = press.action == clipID ? 61_440 : 15_360
    let stamp = TriggerStamp(id: TriggerID(validated: press.id), action: press.action,
                             originHost: HostStamp(ticks: press.originHostTicks), horizonFrame: press.horizonFrame,
                             requires: requires, target: .grid(ticks: grid), latePolicy: .nextBoundary(gridTicks: nil))
    return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: grid), note: note))
}

private func generationEntry(_ seq: Int, counter: GenerationKey, to: Int,
                             reason: GenerationBumpReason) throws -> TimelineV1Entry {
    .generation(try GenerationV1Record.make(counter: counter, from: generation(to - 1), to: generation(to),
                                            reason: reason, seq: seq))
}

private func staleOutcome(_ seq: Int, trigger id: StaticString, result: OutcomeResult,
                          counter: GenerationKey) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: result, stale: .generation(counter))
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

private func firedOutcome(_ seq: Int) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: "trg.4"), result: .fired, assignedFrame: 96_000,
                                 frame: 96_000, musicalMap: .initial)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

/// The eleven entries of the example; `retryHorizon` is the horizon of the retried trigger at seq 8.
private func timelineEntries(retryHorizon: Int64 = 20_256) throws -> [TimelineV1Entry] {
    let scope = GenerationKey(.cancelScope, setVerse)
    let context = GenerationKey(.context, ctxMain)
    return [
        try anchorEntry(1),
        try triggerEntry(2, Press(id: "trg.1", action: clipID, originHostTicks: 2_405_000_000, horizonFrame: 10_256),
                         context: 1, cancelScope: 1),
        try triggerEntry(3, Press(id: "trg.2", action: sceneID, originHostTicks: 2_406_000_000, horizonFrame: 12_256),
                         context: 1, cancelScope: 1),
        try generationEntry(4, counter: scope, to: 2, reason: .userCancel),
        try staleOutcome(5, trigger: "trg.1", result: .cancelled, counter: scope),
        try staleOutcome(6, trigger: "trg.2", result: .cancelled, counter: scope),
        try generationEntry(7, counter: context, to: 2, reason: .contextChange),
        try triggerEntry(8, Press(id: "trg.3", action: clipID, originHostTicks: 2_405_000_000,
                                  horizonFrame: retryHorizon),
                         context: 1, cancelScope: 1, note: "A retry of trg.1 with its original stamps."),
        try staleOutcome(9, trigger: "trg.3", result: .rejectedStale, counter: context),
        try triggerEntry(10, Press(id: "trg.4", action: clipID, originHostTicks: 2_410_000_000, horizonFrame: 20_256),
                         context: 2, cancelScope: 2),
        try firedOutcome(11)]
}

private func timelineRecord(retryHorizon: Int64 = 20_256) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(retryHorizon: retryHorizon))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(retryHorizon: Int64 = 20_256) throws -> Data {
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
    document["timeline"] = try parse(timelineRecord(retryHorizon: retryHorizon).encodedJSON())
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
    struct TraceExample06 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + exampleOnlyKeys))
            #expect(keys.count == 10)
        }

        @Test func clocksSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: clocksRecord().encodedJSON())
            #expect(built == (try exampleSection("clocks")))
        }

        @Test func initialGenerationsSectionEqualsTheBuilderWithTheCancelScopeKey() throws {
            let built = try canonical(builderBytes: initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
            let section = try #require(exampleObject()["initialGenerations"] as? [String: Any])
            #expect(section.count == 5)
            #expect(section["cancelScope/set.verse"] as? Int == 1)
        }

        @Test func actionsSectionEqualsTheBuilderAndTheStateActionHasNoTimePolicy() throws {
            let built = try canonical(builderBytes: actionsRecord().encodedJSON())
            #expect(built == (try exampleSection("actions")))
            let section = try #require(exampleObject()["actions"] as? [[String: Any]])
            #expect(section.count == 2)
            #expect(section.last?["timePolicy"] == nil)
        }

        @Test func timelineSectionEqualsTheBuilderOverElevenEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...11))
            #expect(entries.map(\.kind) == ["anchor", "trigger", "trigger", "generation", "outcome", "outcome",
                                            "generation", "trigger", "outcome", "trigger", "outcome"])
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

        @Test func generationRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "generation")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func outcomeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "outcome")
            #expect(records.example.count == 4)
            #expect(records.built == records.example)
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(retryHorizon: 20_257) != expected)
            #expect(try canonical(builderBytes: timelineRecord(retryHorizon: 20_257).encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
