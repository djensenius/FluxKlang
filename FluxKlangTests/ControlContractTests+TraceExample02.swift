//
//  ControlContractTests+TraceExample02.swift
//  FluxKlangTests
//
//  Media contract example 02 (#84 EXG2) rebuilt from the v1 trace builders: the `clocks`, `actions`,
//  `initialGenerations` and `timeline` sections, each record of the timeline, and the whole document, all compared
//  with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed value;
//  nothing is decoded from the example and nothing is read from disk.
//
//  The literal below is a verbatim copy of
//  docs/transformation/media-contract/examples/02-late-and-retroactive-cue.json, whose SHA-256 is
//  799903170f9c1cdc980aa5486d7453ccd0055a57b37a8275fdea4f8ee26f2373. No builder produces the keys `contract`,
//  `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//

import Foundation
import Testing
@testable import FluxKlang

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "initialGenerations", "actions", "timeline"]

// swiftlint:disable line_length
private let example02 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.02-late-and-retroactive-cue",
  "title": "Late and retroactive cues: join in progress, retroactive window exceeded, bounded fire-late, drop, and next boundary on the trigger's grid",
  "covers": ["lateCue", "retroactiveCue"],
  "notes": [
    "120 BPM at 48 kHz: 1.5625 frames per tick, beat = 24000 frames, 4/4 bar = 96000 frames.",
    "horizonFrame is the earliest frame the scheduler can still affect when the trigger arrives.",
    "trg.5 overrides act.scene's beat grid with a half-note grid, so nextBoundary moves its missed boundary (336000) to the next half note (384000), not the next beat (360000)."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "actions": [
    {"actionId": "act.loop-a", "media": "audio", "timePolicy": "fixedRate", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "joinInProgress", "maxLatenessMs": 50, "retroactiveMs": 40}, "notReady": "dropAndReport", "readiness": "ready", "prefetch": {"blockFrames": 4096, "blockCount": 16, "headFrames": 48000}},
    {"actionId": "act.stab", "media": "midi", "timePolicy": "tempoFollowing", "quantize": {"timeBase": "musical", "gridTicks": 15360}, "late": {"policy": "fireLate", "maxLatenessMs": 10}, "notReady": "dropAndReport", "readiness": "ready"},
    {"actionId": "act.fx", "media": "state", "quantize": {"timeBase": "musical", "gridTicks": 15360}, "late": {"policy": "drop"}, "notReady": "dropAndReport", "readiness": "ready"},
    {"actionId": "act.scene", "media": "state", "quantize": {"timeBase": "musical", "gridTicks": 15360}, "late": {"policy": "nextBoundary"}, "notReady": "dropAndReport", "readiness": "ready"}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "trigger", "triggerId": "trg.1", "actionId": "act.loop-a", "originHostTicks": 2448240000, "horizonFrame": 96736, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "note": "Pressed 10 ms after bar 2: inside the 40 ms retroactive window."},
    {"seq": 3, "kind": "outcome", "triggerId": "trg.1", "result": "joined", "assignedFrame": 96000, "frame": 96736, "startOffsetFrames": 736, "musicalMap": 1},
    {"seq": 4, "kind": "trigger", "triggerId": "trg.2", "actionId": "act.loop-a", "originHostTicks": 2498400000, "horizonFrame": 197056, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "note": "Pressed 100 ms after bar 3: outside the window, so the next bar."},
    {"seq": 5, "kind": "outcome", "triggerId": "trg.2", "result": "fired", "assignedFrame": 288000, "frame": 288000, "musicalMap": 1},
    {"seq": 6, "kind": "trigger", "triggerId": "trg.3", "actionId": "act.stab", "originHostTicks": 2555952000, "horizonFrame": 312160, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "note": "Beat boundary is 160 frames (3.3 ms) behind the horizon."},
    {"seq": 7, "kind": "outcome", "triggerId": "trg.3", "result": "firedLate", "assignedFrame": 312000, "frame": 312160, "musicalMap": 1},
    {"seq": 8, "kind": "trigger", "triggerId": "trg.4", "actionId": "act.fx", "originHostTicks": 2567976000, "horizonFrame": 336208, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}},
    {"seq": 9, "kind": "outcome", "triggerId": "trg.4", "result": "dropped", "reason": "late", "assignedFrame": 336000},
    {"seq": 10, "kind": "trigger", "triggerId": "trg.5", "actionId": "act.scene", "originHostTicks": 2567976000, "horizonFrame": 336208, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "target": {"timeBase": "musical", "gridTicks": 30720}},
    {"seq": 11, "kind": "outcome", "triggerId": "trg.5", "result": "fired", "assignedFrame": 384000, "frame": 384000, "musicalMap": 1}]}
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
    try #require(try parse(Data(example02.utf8)) as? [String: Any])
}

/// One section of the example, in canonical form.
private func exampleSection(_ key: String) throws -> Data {
    try canonical(#require(exampleObject()[key], "\(key)"))
}

// MARK: - Builder inputs

/// One action of the example: its ID, its policy and the grid its `quantize` declares.
private struct ActionSpec {
    let id: ActionID
    let policy: ActionPolicy
    let grid: Int64
    let prefetch: PrefetchPlan?
}

private func loopASpec() throws -> ActionSpec {
    let policy = try ActionPolicy(media: .audio, timePolicy: .fixedRate,
                                  latePolicy: .joinInProgress(maxLatenessMs: 50), gridTicks: 61_440,
                                  retroactiveMs: 40)
    let plan = try PrefetchPlan.make(blockFrames: 4_096, blockCount: 16, headFrames: 48_000)
    return ActionSpec(id: ActionID(validated: "act.loop-a"), policy: policy, grid: 61_440, prefetch: plan)
}

private func stabSpec() throws -> ActionSpec {
    let policy = try ActionPolicy(media: .midi, timePolicy: .tempoFollowing, latePolicy: .fireLate(maxLatenessMs: 10),
                                  gridTicks: 15_360)
    return ActionSpec(id: ActionID(validated: "act.stab"), policy: policy, grid: 15_360, prefetch: nil)
}

private func effectSpec() throws -> ActionSpec {
    let policy = try ActionPolicy(media: .state, timePolicy: nil, latePolicy: .drop, gridTicks: 15_360)
    return ActionSpec(id: ActionID(validated: "act.fx"), policy: policy, grid: 15_360, prefetch: nil)
}

private func sceneSpec() throws -> ActionSpec {
    let policy = try ActionPolicy(media: .state, timePolicy: nil, latePolicy: .nextBoundary(gridTicks: nil),
                                  gridTicks: 15_360)
    return ActionSpec(id: ActionID(validated: "act.scene"), policy: policy, grid: 15_360, prefetch: nil)
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
        GenerationKey(.context, ClockID(validated: "ctx.main")): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

private func actionsRecord() throws -> ActionsV1Record {
    let records = try [loopASpec(), stabSpec(), effectSpec(), sceneSpec()].map { spec in
        try ActionV1Record.make(id: spec.id, policy: spec.policy, quantize: .grid(ticks: spec.grid),
                                readiness: .ready, prefetch: spec.prefetch)
    }
    return try ActionsV1Record.make(records)
}

private func anchorEntry(_ seq: Int) throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 0, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: 0),
                             host: HostStamp(ticks: 2_400_000_000), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

/// A trigger of `action`; `target` is the trigger's own target, which the record writes only when it differs
/// from the action's declared grid (the `quantize:` argument).
private func triggerEntry(_ seq: Int, id: StaticString, action: ActionSpec, originHostTicks: UInt64,
                          horizonFrame: Int64, target: Int64? = nil, note: String? = nil) throws -> TimelineV1Entry {
    let requires = [GenerationRequirement(key: GenerationKey(.context, ClockID(validated: "ctx.main")),
                                          generation: .initial),
                    GenerationRequirement(key: GenerationKey(.sampleClock, smpMain), generation: .initial),
                    GenerationRequirement(key: GenerationKey(.transport, musMain), generation: .initial)]
    let stamp = TriggerStamp(id: TriggerID(validated: id), action: action.id,
                             originHost: HostStamp(ticks: originHostTicks), horizonFrame: horizonFrame,
                             requires: requires, target: .grid(ticks: target ?? action.grid),
                             latePolicy: action.policy.latePolicy, retroactiveMs: action.policy.retroactiveMs)
    return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: action.grid), note: note))
}

private func outcomeEntry(_ seq: Int, _ outcome: TriggerOutcome) throws -> TimelineV1Entry {
    .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

/// The eleven entries of the example; `sceneTarget` is the half-note grid trg.5 overrides act.scene's grid with.
private func timelineEntries(sceneTarget: Int64 = 30_720) throws -> [TimelineV1Entry] {
    let (loopA, stab, effect, scene) = try (loopASpec(), stabSpec(), effectSpec(), sceneSpec())
    let joined = TriggerOutcome(trigger: TriggerID(validated: "trg.1"), result: .joined, assignedFrame: 96_000,
                                frame: 96_736, startOffsetFrames: 736, musicalMap: .initial)
    let onBar = TriggerOutcome(trigger: TriggerID(validated: "trg.2"), result: .fired, assignedFrame: 288_000,
                               frame: 288_000, musicalMap: .initial)
    let late = TriggerOutcome(trigger: TriggerID(validated: "trg.3"), result: .firedLate, assignedFrame: 312_000,
                              frame: 312_160, musicalMap: .initial)
    let dropped = TriggerOutcome(trigger: TriggerID(validated: "trg.4"), result: .dropped, reason: .late,
                                 assignedFrame: 336_000)
    let halfNote = TriggerOutcome(trigger: TriggerID(validated: "trg.5"), result: .fired, assignedFrame: 384_000,
                                  frame: 384_000, musicalMap: .initial)
    return [
        try anchorEntry(1),
        try triggerEntry(2, id: "trg.1", action: loopA, originHostTicks: 2_448_240_000, horizonFrame: 96_736,
                         note: "Pressed 10 ms after bar 2: inside the 40 ms retroactive window."),
        try outcomeEntry(3, joined),
        try triggerEntry(4, id: "trg.2", action: loopA, originHostTicks: 2_498_400_000, horizonFrame: 197_056,
                         note: "Pressed 100 ms after bar 3: outside the window, so the next bar."),
        try outcomeEntry(5, onBar),
        try triggerEntry(6, id: "trg.3", action: stab, originHostTicks: 2_555_952_000, horizonFrame: 312_160,
                         note: "Beat boundary is 160 frames (3.3 ms) behind the horizon."),
        try outcomeEntry(7, late),
        try triggerEntry(8, id: "trg.4", action: effect, originHostTicks: 2_567_976_000, horizonFrame: 336_208),
        try outcomeEntry(9, dropped),
        try triggerEntry(10, id: "trg.5", action: scene, originHostTicks: 2_567_976_000, horizonFrame: 336_208,
                         target: sceneTarget),
        try outcomeEntry(11, halfNote)]
}

private func timelineRecord(sceneTarget: Int64 = 30_720) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(sceneTarget: sceneTarget))
}

/// The whole document: the four builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(sceneTarget: Int64 = 30_720) throws -> Data {
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
    document["timeline"] = try parse(timelineRecord(sceneTarget: sceneTarget).encodedJSON())
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
    struct TraceExample02 {
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

        @Test func actionsSectionEqualsTheBuilderWithTheFourLatePolicies() throws {
            let built = try canonical(builderBytes: actionsRecord().encodedJSON())
            #expect(built == (try exampleSection("actions")))
            let section = try #require(exampleObject()["actions"] as? [[String: Any]])
            try #require(section.count == 4)
            let join = try #require(section.first?["late"] as? [String: Any])
            #expect(join["maxLatenessMs"] as? Int == 50)
            #expect(join["retroactiveMs"] as? Int == 40)
            let fireLate = try #require(section[1]["late"] as? [String: Any])
            #expect(fireLate["maxLatenessMs"] as? Int == 10)
            #expect(section[2]["timePolicy"] == nil && section[3]["timePolicy"] == nil)
        }

        @Test func timelineSectionEqualsTheBuilderOverElevenEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...11))
            #expect(entries.map(\.kind) == ["anchor", "trigger", "outcome", "trigger", "outcome", "trigger",
                                            "outcome", "trigger", "outcome", "trigger", "outcome"])
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func triggerRecordsEqualTheExampleRecordsAndOnlyTheLastCarriesATarget() throws {
            let records = try timelineRecords(kind: "trigger")
            #expect(records.example.count == 5)
            #expect(records.built == records.example)
            let targets = try records.built.map { try #require(parse($0) as? [String: Any])["target"] != nil }
            #expect(targets == [false, false, false, false, true])
        }

        @Test func outcomeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "outcome")
            #expect(records.example.count == 5)
            #expect(records.built == records.example)
        }

        @Test func wholeDocumentEqualsTheFourBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(sceneTarget: 61_440) != expected)
            #expect(try canonical(builderBytes: timelineRecord(sceneTarget: 61_440).encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
