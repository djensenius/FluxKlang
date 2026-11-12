//
//  ControlContractTests+TraceExample04.swift
//  FluxKlangTests
//
//  Media contract example 04 (#84 EXG6) rebuilt from the v1 trace builders: the `clocks`, `streams`, `actions`,
//  `initialGenerations` and `timeline` sections, each record of the timeline, and the whole document, all compared
//  with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed value;
//  nothing is decoded from the example and nothing is read from disk. Unlike example 03 there is no
//  normalization: the example's anchors carry no `loopIteration`.
//
//  The literal below is a verbatim copy of docs/transformation/media-contract/examples/04-tempo-mutation.json,
//  whose SHA-256 is 7bdebbdb3a386308daea3bd6dc08e8c61319133ef515f94417746fc1467c2909. No builder produces the keys
//  `contract`, `version`, `exampleId`, `title`, `covers`, `notes` and `adapterCapabilities` (nothing in `Shared/`
//  builds the last); they are copied from the parsed example.
//
//  The SMF `export` record (seq 13) comes from a SYNTHETIC `SMFWriteResult` (format 1, division 960 header, typed
//  losses): this proves the record builder, not that the real exporter writes these values. The capture of seq 12
//  is built as `example04Log()` of `ControlContractTests+SMFExportV1Examples.swift` does (its own copy, since that
//  one is file-private): through the anchors of seq 1 and 6 and the edited map.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixture = MIDICaptureFixture

private let smpMain = ClockID(validated: "smp.main")
private let musMain = ClockID(validated: "mus.main")
private let ctxMain = ClockID(validated: "ctx.main")
private let padsIn = StreamID(validated: "str.pads-in")
private let drums = ActionID(validated: "act.drums")
private let backing = ActionID(validated: "act.backing")
private let stretch = ActionID(validated: "act.stretch")
private let copiedKeys = ["contract", "version", "exampleId", "title", "covers", "notes", "adapterCapabilities"]
private let builderKeys = ["clocks", "streams", "actions", "initialGenerations", "timeline"]
private let exampleKinds = ["anchor", "trigger", "outcome", "trigger", "generation", "anchor", "outcome",
                            "readiness", "readiness", "trigger", "outcome", "midiCapture", "export"]

// swiftlint:disable line_length
private let example04 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.04-tempo-mutation",
  "title": "Tempo and meter edit: musical targets re-resolve without cancellation; fixed-rate audio is the default; unavailable time-stretch fails readiness",
  "covers": ["tempoMutation", "fixedRateDefault", "timeStretchPolicy", "readiness"],
  "notes": [
    "The edit changes tempo to 150 BPM from tick 122880 (1.25 frames per tick) and the meter to 3/4; musicalMap revisions never cancel triggers.",
    "act.backing keeps its sample length after the edit (fixed rate); a tempo mismatch is advisory, not a silent stretch."],
  "adapterCapabilities": {"timeStretch": false},
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}]}},
  "streams": [{"streamId": "str.pads-in", "ordinal": 0, "media": "midi", "direction": "capture"}],
  "actions": [
    {"actionId": "act.drums", "media": "midi", "timePolicy": "tempoFollowing", "quantize": {"timeBase": "musical", "gridTicks": 15360}, "late": {"policy": "nextBoundary"}, "notReady": "dropAndReport", "readiness": "ready"},
    {"actionId": "act.backing", "media": "audio", "timePolicy": "fixedRate", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "joinInProgress", "maxLatenessMs": 50}, "notReady": "dropAndReport", "readiness": "ready", "prefetch": {"blockFrames": 4096, "blockCount": 16, "headFrames": 48000}},
    {"actionId": "act.stretch", "media": "audio", "timePolicy": "timeStretch", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "drop"}, "notReady": "dropAndReport", "readiness": "unprepared", "prefetch": {"blockFrames": 4096, "blockCount": 16, "headFrames": 48000}}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0},
    {"seq": 2, "kind": "trigger", "triggerId": "trg.1", "actionId": "act.backing", "originHostTicks": 2400500000, "horizonFrame": 1256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}},
    {"seq": 3, "kind": "outcome", "triggerId": "trg.1", "result": "fired", "assignedFrame": 96000, "frame": 96000, "musicalMap": 1},
    {"seq": 4, "kind": "trigger", "triggerId": "trg.2", "actionId": "act.drums", "originHostTicks": 2450000000, "horizonFrame": 100256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "target": {"timeBase": "musical", "atTicks": 184320}, "note": "Bar 4 beat 1 was frame 288000 at the old tempo."},
    {"seq": 5, "kind": "generation", "counter": "musicalMap/mus.main", "from": 1, "to": 2, "reason": "tempoEdit", "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}, {"atTicks": 122880, "microsPerQuarter": 400000}], "meter": {"numerator": 3, "denominator": 4}},
    {"seq": 6, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 192000, "hostTicks": 2496000000, "transport": 1, "musicalTicks": 122880},
    {"seq": 7, "kind": "outcome", "triggerId": "trg.2", "result": "fired", "assignedFrame": 268800, "frame": 268800, "musicalMap": 2},
    {"seq": 8, "kind": "readiness", "actionId": "act.stretch", "from": "unprepared", "to": "preparing"},
    {"seq": 9, "kind": "readiness", "actionId": "act.stretch", "from": "preparing", "to": "failed", "reason": "timeStretchUnavailable"},
    {"seq": 10, "kind": "trigger", "triggerId": "trg.3", "actionId": "act.stretch", "originHostTicks": 2500000000, "horizonFrame": 200256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}},
    {"seq": 11, "kind": "outcome", "triggerId": "trg.3", "result": "dropped", "reason": "notReady", "note": "No silent fallback to fixed rate."},
    {"seq": 12, "kind": "midiCapture", "stream": "str.pads-in", "ump": ["0x20903C64"], "hostTicks": 2484000000, "frame": 168000, "musicalTicks": 107520, "endpointProtocol": "midi1", "portProtocol": "midi1", "translatedBy": "none", "effective": "midi1", "note": "Delivered after the seq 6 anchor: frame 168000 maps back across the 120 BPM segment to tick 107520; SMF export inverts it through that same anchor."},
    {"seq": 13, "kind": "export", "exportId": "exp.smf", "streams": ["str.pads-in"], "format": "smf", "smfFormat": 1, "division": 960, "lossless": true, "losses": {}}]}
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
    try #require(try parse(Data(example04.utf8)) as? [String: Any])
}

/// One section of the example, in canonical form.
private func exampleSection(_ key: String) throws -> Data {
    try canonical(#require(exampleObject()[key], "\(key)"))
}

private func exampleTimeline() throws -> [[String: Any]] {
    try #require(exampleObject()["timeline"] as? [[String: Any]])
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

private func streamsRecord() throws -> StreamsV1Record {
    try StreamsV1Record.make([StreamsV1Record.Stream(id: padsIn, ordinal: 0, media: .midi, direction: .capture)])
}

private func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, smpMain): .initial,
        GenerationKey(.transport, musMain): .initial,
        GenerationKey(.musicalMap, musMain): .initial,
        GenerationKey(.context, ctxMain): .initial
    ]
    return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
}

private func actionsRecord() throws -> ActionsV1Record {
    let drumsPolicy = try ActionPolicy(media: .midi, timePolicy: .tempoFollowing,
                                       latePolicy: .nextBoundary(gridTicks: nil), gridTicks: 15_360)
    let backingPolicy = try ActionPolicy(media: .audio, timePolicy: .fixedRate,
                                         latePolicy: .joinInProgress(maxLatenessMs: 50), gridTicks: 61_440)
    let stretchPolicy = try ActionPolicy(media: .audio, timePolicy: .timeStretch, latePolicy: .drop,
                                         gridTicks: 61_440)
    let plan = try PrefetchPlan.make(blockFrames: 4_096, blockCount: 16, headFrames: 48_000)
    return try ActionsV1Record.make([
        ActionV1Record.make(id: drums, policy: drumsPolicy, quantize: .grid(ticks: 15_360), readiness: .ready),
        ActionV1Record.make(id: backing, policy: backingPolicy, quantize: .grid(ticks: 61_440), readiness: .ready,
                            prefetch: plan),
        ActionV1Record.make(id: stretch, policy: stretchPolicy, quantize: .grid(ticks: 61_440),
                            readiness: .unprepared, prefetch: plan)])
}

private func anchorEntry(_ seq: Int, frame: Int64, host: UInt64, ticks: Int64,
                         musicalMap: Generation = .initial) throws -> TimelineV1Entry {
    let musical = MusicalStamp(transport: .initial, musicalMap: musicalMap, ticks: ticks, loopIteration: 0)
    let anchor = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: frame),
                             host: HostStamp(ticks: host), musical: musical)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

/// What a trigger names. `target` is what the stamp resolved to; `grid` is the action's declared quantize.
private struct Press {
    let id: StaticString
    let action: ActionID
    let grid: Int64
    let late: LatePolicy
    let originHostTicks: UInt64
    let horizonFrame: Int64
    var target: TriggerTarget?
    var note: String?
}

private func triggerEntry(_ seq: Int, _ press: Press) throws -> TimelineV1Entry {
    let requires = [GenerationRequirement(key: GenerationKey(.sampleClock, smpMain), generation: .initial),
                    GenerationRequirement(key: GenerationKey(.transport, musMain), generation: .initial),
                    GenerationRequirement(key: GenerationKey(.context, ctxMain), generation: .initial)]
    let stamp = TriggerStamp(id: TriggerID(validated: press.id), action: press.action,
                             originHost: HostStamp(ticks: press.originHostTicks), horizonFrame: press.horizonFrame,
                             requires: requires, target: press.target ?? .grid(ticks: press.grid),
                             latePolicy: press.late)
    return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: press.grid), note: press.note))
}

private func firedEntry(_ seq: Int, trigger id: StaticString, frame: Int64, map: Generation) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: .fired, assignedFrame: frame,
                                 frame: frame, musicalMap: map)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

private func droppedEntry(_ seq: Int) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(trigger: TriggerID(validated: "trg.3"), result: .dropped, reason: .notReady)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq, note: "No silent fallback to fixed rate."))
}

private func tempoEdit(_ seq: Int, slowTempo: Int64) throws -> TimelineV1Entry {
    let edited = try MusicalMap(clock: musMain, revision: generation(2), segments: [
        TempoSegment(atTicks: 0, microsPerQuarter: 500_000), TempoSegment(atTicks: 122_880, microsPerQuarter: slowTempo)
    ])
    let meter = try MusicalMeter(MeterFields(numerator: 3, denominator: 4))
    return .generation(try GenerationV1Record.make(counter: GenerationKey(.musicalMap, musMain), from: .initial,
                                                   to: generation(2), reason: .tempoEdit, musicalMap: edited,
                                                   meter: meter, seq: seq))
}

private func readinessEntry(_ seq: Int, from: ReadinessState, to: ReadinessState,
                            reason: String? = nil) throws -> TimelineV1Entry {
    .readiness(try ReadinessV1Record.make(stretch, from: from, to: to, seq: seq, reason: reason))
}

/// A pad capture after the tempo edit's anchor, delivered through the first anchor and the edited map.
private func padCaptureLog() throws -> MIDICaptureLog {
    var log = try Fixture.log([padsIn])
    let first = try Fixture.anchor(1, frame: 0, host: 2_400_000_000, transport: 1)
    try log.observe(anchor: first)
    let revision = try Generation(2)
    try log.observe(anchor: ClockAnchor(
        sample: SampleStamp(clock: Fixture.clock, generation: .initial, frame: 192_000),
        host: HostStamp(ticks: 2_496_000_000),
        musical: MusicalStamp(transport: .initial, musicalMap: revision, ticks: 122_880, loopIteration: 0)))
    let edited = try MusicalMap(clock: Fixture.musicalClock, revision: revision,
                                segments: [TempoSegment(atTicks: 0, microsPerQuarter: 500_000),
                                           TempoSegment(atTicks: 122_880, microsPerQuarter: 400_000)])
    let map = try MusicalClockMap(anchor: first, map: edited, nominalRate: 48_000, currentSample: .initial,
                                  currentTransport: .initial)
    _ = try log.capture([0x2090_3C64], stream: padsIn, host: HostStamp(ticks: 2_484_000_000), endpoint: .midi1,
                        port: .midi1, musicalMap: map, current: .initial)
    return log
}

private func captureEntry(_ seq: Int) throws -> TimelineV1Entry {
    let records = try padCaptureLog().records
    try #require(records.count == 1)
    let note = "Delivered after the seq 6 anchor: frame 168000 maps back across the 120 BPM segment to tick 107520; "
        + "SMF export inverts it through that same anchor."
    return .midiCapture(try MIDICaptureV1Record.make(records[0], seq: seq, note: note))
}

/// The SMF export record over a synthetic header-only file: format 1, two tracks, division 960, and `losses`
/// passes overlaid (none in the example).
private func smfExportEntry(_ seq: Int, losses: Int) throws -> TimelineV1Entry {
    let header: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x01, 0x00, 0x02, 0x03, 0xC0]
    let report = SMFExportLossReport(losses: losses == 0 ? [:] : [.passesOverlaid: losses])
    let file = SMFWriteResult(bytes: header, losses: report, reorderedItems: 0)
    return .smfExport(try SMFExportV1Record.make(file, streams: [padsIn], exportID: ExportID(validated: "exp.smf"),
                                                 seq: seq))
}

/// The 13 entries of the example; `slowTempo` is the second tempo segment, `horizon` trg.3's horizon frame and
/// `losses` the loss count of the export record, so a test can change one input.
private func timelineEntries(slowTempo: Int64 = 400_000, horizon: Int64 = 200_256,
                             losses: Int = 0) throws -> [TimelineV1Entry] {
    let next = LatePolicy.nextBoundary(gridTicks: nil)
    let join = LatePolicy.joinInProgress(maxLatenessMs: 50)
    return [
        try anchorEntry(1, frame: 0, host: 2_400_000_000, ticks: 0),
        try triggerEntry(2, Press(id: "trg.1", action: backing, grid: 61_440, late: join,
                                  originHostTicks: 2_400_500_000, horizonFrame: 1_256)),
        try firedEntry(3, trigger: "trg.1", frame: 96_000, map: .initial),
        try triggerEntry(4, Press(id: "trg.2", action: drums, grid: 15_360, late: next,
                                  originHostTicks: 2_450_000_000, horizonFrame: 100_256,
                                  target: .musical(atTicks: 184_320),
                                  note: "Bar 4 beat 1 was frame 288000 at the old tempo.")),
        try tempoEdit(5, slowTempo: slowTempo),
        try anchorEntry(6, frame: 192_000, host: 2_496_000_000, ticks: 122_880, musicalMap: generation(2)),
        try firedEntry(7, trigger: "trg.2", frame: 268_800, map: generation(2)),
        try readinessEntry(8, from: .unprepared, to: .preparing),
        try readinessEntry(9, from: .preparing, to: .failed, reason: "timeStretchUnavailable"),
        try triggerEntry(10, Press(id: "trg.3", action: stretch, grid: 61_440, late: .drop,
                                   originHostTicks: 2_500_000_000, horizonFrame: horizon)),
        try droppedEntry(11),
        try captureEntry(12),
        try smfExportEntry(13, losses: losses)]
}

private func timelineRecord(slowTempo: Int64 = 400_000, horizon: Int64 = 200_256,
                            losses: Int = 0) throws -> TimelineV1Record {
    try TimelineV1Record.make(timelineEntries(slowTempo: slowTempo, horizon: horizon, losses: losses))
}

/// The entries as the records they encode to.
private func builtRecords(_ entries: [TimelineV1Entry]) throws -> [[String: Any]] {
    try entries.map { try #require(parse(ContractCoding.makeEncoder().encode($0)) as? [String: Any]) }
}

/// The whole document: the five builder sections plus the seven keys no builder produces, in canonical form.
private func rebuiltDocument(slowTempo: Int64 = 400_000, horizon: Int64 = 200_256,
                             losses: Int = 0) throws -> Data {
    var document: [String: Any] = [:]
    let example = try exampleObject()
    for key in copiedKeys {
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
    document["timeline"] = try parse(timelineRecord(slowTempo: slowTempo, horizon: horizon, losses: losses)
        .encodedJSON())
    return try canonical(document)
}

/// The example's timeline records of the given `kind`, in seq order, with the entries built for them.
private func timelineRecords(kind: String) throws -> (example: [Data], built: [Data]) {
    let records = try exampleTimeline()
    let entries = try timelineEntries()
    try #require(records.count == entries.count)
    var example: [Data] = [], built: [Data] = []
    for (record, entry) in zip(records, entries) where record["kind"] as? String == kind {
        example.append(try canonical(record))
        built.append(try canonical(builderBytes: ContractCoding.makeEncoder().encode(entry)))
    }
    return (example, built)
}

/// Each trigger paired with its first later outcome: `"trg.1:2>3"`.
private func triggerChains(_ records: [[String: Any]]) -> [String] {
    records.compactMap { record in
        guard record["kind"] as? String == "trigger", let id = record["triggerId"] as? String,
              let seq = record["seq"] as? Int else { return nil }
        let outcome = records.first {
            $0["kind"] as? String == "outcome" && $0["triggerId"] as? String == id && ($0["seq"] as? Int ?? 0) > seq
        }
        return "\(id):\(seq)>\(outcome?["seq"] as? Int ?? 0)"
    }
}

extension ControlContractTests {
    struct TraceExample04 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSevenCopiedKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + copiedKeys))
            #expect(keys.count == 12)
        }

        @Test func clocksSectionEqualsTheBuilderWithOneTempoEntryAndNoLoop() throws {
            let built = try canonical(builderBytes: clocksRecord().encodedJSON())
            #expect(built == (try exampleSection("clocks")))
            let clocks = try #require(exampleObject()["clocks"] as? [String: Any])
            let musical = try #require(clocks["musical"] as? [String: Any])
            #expect(musical["loop"] == nil)
            #expect((musical["musicalMap"] as? [Any])?.count == 1)
        }

        @Test func streamsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: streamsRecord().encodedJSON())
            #expect(built == (try exampleSection("streams")))
        }

        @Test func actionsSectionEqualsTheBuilderAndTheStretchActionIsUnprepared() throws {
            let built = try canonical(builderBytes: actionsRecord().encodedJSON())
            #expect(built == (try exampleSection("actions")))
            let actions = try #require(exampleObject()["actions"] as? [[String: Any]])
            #expect(actions.map { $0["actionId"] as? String } == ["act.drums", "act.backing", "act.stretch"])
            #expect(actions.map { $0["readiness"] as? String } == ["ready", "ready", "unprepared"])
            #expect(actions.last?["timePolicy"] as? String == "timeStretch")
        }

        @Test func initialGenerationsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
        }

        @Test func timelineSectionEqualsTheBuilderOverThirteenEntries() throws {
            let entries = try timelineEntries()
            #expect(entries.map(\.seq) == Array(1...13))
            #expect(entries.map(\.kind) == exampleKinds)
            #expect(try exampleTimeline().compactMap { $0["kind"] as? String } == exampleKinds)
            let built = try canonical(builderBytes: timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordsEqualTheExampleRecordsAndCarryNoLoopIteration() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
            #expect(try exampleTimeline().allSatisfy { $0["loopIteration"] == nil })
        }

        @Test func triggerRecordsEqualTheExampleRecordsAndOnlyTrg2CarriesATarget() throws {
            let records = try timelineRecords(kind: "trigger")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
            let built = try builtRecords(timelineEntries())
            try #require(built.count == 13)
            #expect([1, 9].map { built[$0]["target"] == nil } == [true, true])
            let target = try #require(built[3]["target"] as? [String: Any])
            #expect(target["timeBase"] as? String == "musical" && target["atTicks"] as? Int == 184_320)
        }

        @Test func generationRecordEqualsTheExampleRecordWithTheEditedMapAndMeter() throws {
            let records = try timelineRecords(kind: "generation")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
            let built = try builtRecords(timelineEntries())
            try #require(built.count == 13)
            let map = try #require(built[4]["musicalMap"] as? [[String: Int]])
            #expect(map == [["atTicks": 0, "microsPerQuarter": 500_000],
                            ["atTicks": 122_880, "microsPerQuarter": 400_000]])
            #expect(built[4]["meter"] as? [String: Int] == ["numerator": 3, "denominator": 4])
        }

        @Test func outcomeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "outcome")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func readinessRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "readiness")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func midiCaptureRecordEqualsTheExampleRecordMappedThroughTheEditedMap() throws {
            let records = try timelineRecords(kind: "midiCapture")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
            let log = try padCaptureLog()
            #expect(log.records.map(\.sample.frame) == [168_000] && log.records.map(\.musicalTicks) == [107_520])
        }

        @Test func exportRecordEqualsTheExampleRecordFromASyntheticSMFResult() throws {
            let records = try timelineRecords(kind: "export")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
            let record = try #require(exampleTimeline().last)
            #expect(record["smfFormat"] as? Int == 1 && record["division"] as? Int == 960)
            #expect(record["lossless"] as? Bool == true && (record["losses"] as? [String: Int])?.isEmpty == true)
        }

        @Test func eachTriggerHasItsOutcomeLaterInTheBuiltEntriesAndTheExample() throws {
            let expected = ["trg.1:2>3", "trg.2:4>7", "trg.3:10>11"]
            #expect(try triggerChains(builtRecords(timelineEntries())) == expected)
            #expect(try triggerChains(exampleTimeline()) == expected)
        }

        @Test func theStretchActionFailsItsReadinessAndItsTriggerIsDroppedNotReady() throws {
            let built = try builtRecords(timelineEntries())
            try #require(built.count == 13)
            #expect(built[7]["from"] as? String == "unprepared" && built[7]["to"] as? String == "preparing")
            #expect(built[8]["to"] as? String == "failed" && built[8]["reason"] as? String == "timeStretchUnavailable")
            #expect(built[10]["result"] as? String == "dropped" && built[10]["reason"] as? String == "notReady")
            #expect(built[10]["triggerId"] as? String == built[9]["triggerId"] as? String)
        }

        @Test func adapterCapabilitiesIsTheOnlyKeyNoBuilderProducesBesidesTheSixDescriptiveOnes() throws {
            let example = try exampleObject()
            let capabilities = try #require(example["adapterCapabilities"] as? [String: Bool])
            #expect(capabilities == ["timeStretch": false])
            #expect(Set(copiedKeys).subtracting(["contract", "version", "exampleId", "title", "covers", "notes"])
                == ["adapterCapabilities"])
            let document = try #require(parse(rebuiltDocument()) as? [String: Any])
            #expect(try canonical(#require(document["adapterCapabilities"])) == canonical(capabilities))
        }

        @Test func wholeDocumentEqualsTheFiveBuilderSectionsAndTheSevenCopiedKeys() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(exampleObject())
            #expect(try rebuiltDocument(slowTempo: 400_001) != expected)
            #expect(try rebuiltDocument(horizon: 200_257) != expected)
            #expect(try rebuiltDocument(losses: 1) != expected)
            #expect(try canonical(builderBytes: timelineRecord(slowTempo: 400_001).encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
