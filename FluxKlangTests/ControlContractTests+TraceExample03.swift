//
//  ControlContractTests+TraceExample03.swift
//  FluxKlangTests
//
//  Media contract example 03 (#84 EXG6) rebuilt from the v1 trace builders: the `clocks`, `streams`, `actions`,
//  `initialGenerations` and `timeline` sections, each record of the timeline, and the whole document, all compared
//  with a copy of the example in canonical form (sorted keys, re-serialized). Every input is a typed value (see
//  `ControlContractTests+TraceExample03Inputs.swift`); nothing is decoded from the example and nothing is read
//  from disk.
//
//  The literal below is a verbatim copy of docs/transformation/media-contract/examples/03-seek-and-loop.json,
//  whose SHA-256 is 47ce4233c76d0e6f5a18eac5ce0dc8ff8f1ae2a30b75a444b7e6a93616abc3a4. No builder produces the keys
//  `contract`, `version`, `exampleId`, `title`, `covers` and `notes`; they are taken from the copy.
//
//  ONE NORMALIZATION, example side only: the example writes `"loopIteration": 0` on the anchors at seq 1 and 17,
//  and `AnchorV1Record.make` never writes a zero (an absent value reads as 0; the schema and the checker agree).
//  `normalizedExample()` removes the key `loopIteration` from a timeline record of kind `anchor` when, and only
//  when, its value is the JSON number 0. It never touches the builder output, another key, another kind or a
//  non-zero value, and every example-side comparison below goes through it.
//
//  The SMF `export` record (seq 23) comes from a SYNTHETIC `SMFWriteResult` (format 1, division 960 header, typed
//  losses): this proves the record builder, not that the real exporter reproduces these losses at division 960.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Inputs = TraceExample03Inputs

private let exampleOnlyKeys = ["contract", "version", "exampleId", "title", "covers", "notes"]
private let builderKeys = ["clocks", "streams", "actions", "initialGenerations", "timeline"]
private let exampleKinds = ["anchor", "trigger", "discontinuity", "anchor", "dispatch", "dispatch", "dispatch",
                            "outcome", "midiCapture", "midiCapture", "trigger", "generation", "discontinuity",
                            "outcome", "dispatch", "readiness", "anchor", "readiness", "readiness", "trigger",
                            "outcome", "midiCapture", "export"]

// swiftlint:disable line_length
private let example03 = #"""
{
  "contract": "fluxklang.media", "version": 1, "exampleId": "ex.03-seek-and-loop",
  "title": "Loop wrap and locate: a cue and a capture across the wrap keep their pass, same-frame ordering, owned-note release, pending cue cancelled by locate, re-prepared audio",
  "covers": ["seek", "loop", "ordering", "cancellation"],
  "notes": [
    "Loop is two bars [0, 122880) = 192000 frames. A wrap increments loopIteration; it is not a generation.",
    "Ordering key is (frame, lane, streamOrdinal, streamSeq) with lanes release < transport < state < content.",
    "trg.1 and the frame-191000 capture belong to iteration 0 although they complete after the wrap anchor: the cue's missed loop end advances to bar 2 of iteration 1, and the capture keeps tick 122240. SMF export overlays three passes (iterations 0 and 1, then the post-locate pass) on one tick line and declares the two later-pass events (passesOverlaid)."],
  "clocks": {
    "host": {"timebaseNumer": 125, "timebaseDenom": 3}, "sample": [{"clockId": "smp.main", "nominalRate": 48000}],
    "musical": {"clockId": "mus.main", "ticksPerQuarter": 15360, "meter": {"numerator": 4, "denominator": 4}, "musicalMap": [{"atTicks": 0, "microsPerQuarter": 500000}], "loop": {"startTicks": 0, "endTicks": 122880}}},
  "streams": [
    {"streamId": "str.state", "ordinal": 0, "media": "state", "direction": "playback"},
    {"streamId": "str.verse", "ordinal": 1, "media": "midi", "direction": "playback"},
    {"streamId": "str.keys-in", "ordinal": 2, "media": "midi", "direction": "capture"}],
  "actions": [
    {"actionId": "act.verse", "media": "midi", "timePolicy": "tempoFollowing", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "nextBoundary"}, "notReady": "dropAndReport", "readiness": "ready"},
    {"actionId": "act.backing", "media": "audio", "timePolicy": "fixedRate", "quantize": {"timeBase": "musical", "gridTicks": 61440}, "late": {"policy": "joinInProgress", "maxLatenessMs": 50}, "notReady": "dropAndReport", "readiness": "ready", "prefetch": {"blockFrames": 4096, "blockCount": 16, "headFrames": 48000}}],
  "initialGenerations": {
    "sampleClock/smp.main": 1, "transport/mus.main": 1, "musicalMap/mus.main": 1, "context/ctx.main": 1},
  "timeline": [
    {"seq": 1, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 0, "hostTicks": 2400000000, "transport": 1, "musicalTicks": 0, "loopIteration": 0},
    {"seq": 2, "kind": "trigger", "triggerId": "trg.1", "actionId": "act.verse", "originHostTicks": 2495500000, "horizonFrame": 192256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "note": "Resolves to the loop end of iteration 0 (the wrap frame 192000), already behind the horizon."},
    {"seq": 3, "kind": "discontinuity", "type": "loopWrap", "sampleClock": "smp.main", "generation": 1, "frame": 192000},
    {"seq": 4, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 192000, "hostTicks": 2496000000, "transport": 1, "musicalTicks": 0, "loopIteration": 1},
    {"seq": 5, "kind": "dispatch", "frame": 192000, "lane": "release", "stream": "str.verse", "streamSeq": 41, "event": "noteOff 60 (owned note, releaseAtWrap)"},
    {"seq": 6, "kind": "dispatch", "frame": 192000, "lane": "state", "stream": "str.state", "streamSeq": 7, "event": "program 12 (prepared state recall)"},
    {"seq": 7, "kind": "dispatch", "frame": 192000, "lane": "content", "stream": "str.verse", "streamSeq": 42, "event": "noteOn 60"},
    {"seq": 8, "kind": "outcome", "triggerId": "trg.1", "result": "fired", "assignedFrame": 288000, "frame": 288000, "musicalMap": 1, "note": "The wrap does not move the resolved target; nextBoundary advances it to bar 2 of iteration 1."},
    {"seq": 9, "kind": "midiCapture", "stream": "str.keys-in", "ump": ["0x20903C64"], "hostTicks": 2495500000, "frame": 191000, "musicalTicks": 122240, "endpointProtocol": "midi1", "portProtocol": "midi1", "translatedBy": "none", "effective": "midi1", "note": "Event before the wrap, delivered after it: it resolves through iteration 0's anchor."},
    {"seq": 10, "kind": "midiCapture", "stream": "str.keys-in", "ump": ["0x20803C00"], "hostTicks": 2496500000, "frame": 193000, "musicalTicks": 640, "endpointProtocol": "midi1", "portProtocol": "midi1", "translatedBy": "none", "effective": "midi1"},
    {"seq": 11, "kind": "trigger", "triggerId": "trg.2", "actionId": "act.verse", "originHostTicks": 2500000000, "horizonFrame": 200256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 1, "context/ctx.main": 1}, "note": "Resolves to bar 2 of iteration 1 (frame 288000); pending."},
    {"seq": 12, "kind": "generation", "counter": "transport/mus.main", "from": 1, "to": 2, "reason": "locate"},
    {"seq": 13, "kind": "discontinuity", "type": "locate", "sampleClock": "smp.main", "generation": 1, "frame": 210000},
    {"seq": 14, "kind": "outcome", "triggerId": "trg.2", "result": "cancelled", "reason": "transport"},
    {"seq": 15, "kind": "dispatch", "frame": 210000, "lane": "release", "stream": "str.verse", "streamSeq": 43, "event": "all owned notes off (locate)"},
    {"seq": 16, "kind": "readiness", "actionId": "act.backing", "from": "ready", "to": "invalidated", "reason": "locate moved the prefetch head"},
    {"seq": 17, "kind": "anchor", "sampleClock": "smp.main", "generation": 1, "frame": 210000, "hostTicks": 2505000000, "transport": 2, "musicalTicks": 61440, "loopIteration": 0},
    {"seq": 18, "kind": "readiness", "actionId": "act.backing", "from": "invalidated", "to": "preparing"},
    {"seq": 19, "kind": "readiness", "actionId": "act.backing", "from": "preparing", "to": "ready"},
    {"seq": 20, "kind": "trigger", "triggerId": "trg.3", "actionId": "act.backing", "originHostTicks": 2506000000, "horizonFrame": 212256, "requires": {"sampleClock/smp.main": 1, "transport/mus.main": 2, "context/ctx.main": 1}, "note": "Next bar is the loop end, so it resolves to the wrap frame."},
    {"seq": 21, "kind": "outcome", "triggerId": "trg.3", "result": "fired", "assignedFrame": 306000, "frame": 306000, "musicalMap": 1},
    {"seq": 22, "kind": "midiCapture", "stream": "str.keys-in", "ump": ["0x20903E64"], "hostTicks": 2505500000, "frame": 211000, "musicalTicks": 62080, "endpointProtocol": "midi1", "portProtocol": "midi1", "translatedBy": "none", "effective": "midi1"},
    {"seq": 23, "kind": "export", "exportId": "exp.smf", "streams": ["str.keys-in"], "format": "smf", "smfFormat": 1, "division": 960, "lossless": false, "losses": {"passesOverlaid": 2}}]}
"""#
// swiftlint:enable line_length

/// A small document for the normalization rule: only a zero `loopIteration` of an `anchor` goes.
private let normalizationCase = #"""
{"loopIteration": 0, "timeline": [
  {"seq": 1, "kind": "anchor", "loopIteration": 2},
  {"seq": 2, "kind": "anchor", "loopIteration": 0},
  {"seq": 3, "kind": "trigger", "loopIteration": 0},
  {"seq": 4, "kind": "anchor", "loopIteration": false},
  {"seq": 5, "kind": "anchor"}]}
"""#

// MARK: - Canonical form and the one normalization

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

/// The example as written, with no normalization.
private func exampleObject() throws -> [String: Any] {
    try #require(try parse(Data(example03.utf8)) as? [String: Any])
}

/// True for the JSON number 0 (a boolean `false` is not one).
private func isJSONZero(_ value: Any) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    return number.int64Value == 0 && number.doubleValue == 0
}

/// THE normalization: `object` with `loopIteration` removed from every `timeline` record of kind `anchor` whose
/// value is the JSON number 0. Nothing else changes.
private func normalized(_ object: [String: Any]) -> [String: Any] {
    guard let records = object["timeline"] as? [[String: Any]] else { return object }
    var result = object
    result["timeline"] = records.map { record -> [String: Any] in
        guard record["kind"] as? String == "anchor", let value = record["loopIteration"], isJSONZero(value) else {
            return record
        }
        var stripped = record
        stripped["loopIteration"] = nil
        return stripped
    }
    return result
}

private func normalizedExample() throws -> [String: Any] {
    try normalized(exampleObject())
}

/// One section of the normalized example, in canonical form.
private func exampleSection(_ key: String) throws -> Data {
    try canonical(#require(normalizedExample()[key], "\(key)"))
}

private func exampleTimeline() throws -> [[String: Any]] {
    try #require(normalizedExample()["timeline"] as? [[String: Any]])
}

private func rawTimeline() throws -> [[String: Any]] {
    try #require(exampleObject()["timeline"] as? [[String: Any]])
}

// MARK: - Builder output

/// The entries as the records they encode to.
private func builtRecords(_ entries: [TimelineV1Entry]) throws -> [[String: Any]] {
    try entries.map { try #require(parse(ContractCoding.makeEncoder().encode($0)) as? [String: Any]) }
}

/// The whole document: the five builder sections plus the six keys no builder produces, in canonical form.
private func rebuiltDocument(loopEnd: Int64 = 122_880, horizon: Int64 = 192_256,
                             passesOverlaid: Int = 2) throws -> Data {
    var document: [String: Any] = [:]
    let example = try normalizedExample()
    for key in exampleOnlyKeys {
        guard let value = example[key] else {
            Issue.record("the example has no \(key)")
            continue
        }
        document[key] = value
    }
    document["clocks"] = try parse(Inputs.clocksRecord(loopEnd: loopEnd).encodedJSON())
    document["streams"] = try parse(Inputs.streamsRecord().encodedJSON())
    document["actions"] = try parse(Inputs.actionsRecord().encodedJSON())
    document["initialGenerations"] = try parse(Inputs.initialGenerationsRecord().encodedJSON())
    document["timeline"] = try parse(Inputs.timelineRecord(horizon: horizon, passesOverlaid: passesOverlaid)
        .encodedJSON())
    return try canonical(document)
}

/// The normalized example's timeline records of the given `kind`, in seq order, with the entries built for them.
private func timelineRecords(kind: String) throws -> (example: [Data], built: [Data]) {
    let records = try exampleTimeline()
    let entries = try Inputs.timelineEntries()
    try #require(records.count == entries.count)
    var example: [Data] = [], built: [Data] = []
    for (record, entry) in zip(records, entries) where record["kind"] as? String == kind {
        example.append(try canonical(record))
        built.append(try canonical(builderBytes: ContractCoding.makeEncoder().encode(entry)))
    }
    return (example, built)
}

/// Each trigger paired with its first later outcome: `"trg.1:2>8"`.
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
    struct TraceExample03 {
        @Test func exampleKeysAreTheBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let keys = try Set(exampleObject().keys)
            #expect(keys == Set(builderKeys + exampleOnlyKeys))
            #expect(keys.count == 11)
        }

        @Test func clocksSectionEqualsTheBuilderAndPinsTheLoop() throws {
            let built = try canonical(builderBytes: Inputs.clocksRecord().encodedJSON())
            #expect(built == (try exampleSection("clocks")))
            let clocks = try #require(exampleObject()["clocks"] as? [String: Any])
            let musical = try #require(clocks["musical"] as? [String: Any])
            let loop = try #require(musical["loop"] as? [String: Int])
            #expect(loop == ["startTicks": 0, "endTicks": 122_880])
            #expect((musical["musicalMap"] as? [Any])?.count == 1)
        }

        @Test func streamsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: Inputs.streamsRecord().encodedJSON())
            #expect(built == (try exampleSection("streams")))
            let streams = try #require(exampleObject()["streams"] as? [[String: Any]])
            #expect(streams.map { $0["streamId"] as? String } == ["str.state", "str.verse", "str.keys-in"])
            #expect(streams.map { $0["media"] as? String } == ["state", "midi", "midi"])
        }

        @Test func actionsSectionEqualsTheBuilderAndOnlyTheAudioActionPrefetches() throws {
            let built = try canonical(builderBytes: Inputs.actionsRecord().encodedJSON())
            #expect(built == (try exampleSection("actions")))
            let actions = try #require(exampleObject()["actions"] as? [[String: Any]])
            #expect(actions.count == 2)
            #expect(actions.first?["prefetch"] == nil)
            let late = try #require(actions.last?["late"] as? [String: Any])
            #expect(late["policy"] as? String == "joinInProgress" && late["maxLatenessMs"] as? Int == 50)
        }

        @Test func initialGenerationsSectionEqualsTheBuilder() throws {
            let built = try canonical(builderBytes: Inputs.initialGenerationsRecord().encodedJSON())
            #expect(built == (try exampleSection("initialGenerations")))
            let section = try #require(exampleObject()["initialGenerations"] as? [String: Any])
            #expect(section.count == 4)
        }

        @Test func timelineSectionEqualsTheBuilderOverTwentyThreeEntries() throws {
            let entries = try Inputs.timelineEntries()
            #expect(entries.map(\.seq) == Array(1...23))
            #expect(entries.map(\.kind) == exampleKinds)
            #expect(try rawTimeline().compactMap { $0["kind"] as? String } == exampleKinds)
            let built = try canonical(builderBytes: Inputs.timelineRecord().encodedJSON())
            #expect(built == (try exampleSection("timeline")))
        }

        @Test func anchorRecordsEqualTheExampleRecordsAfterTheNormalization() throws {
            let records = try timelineRecords(kind: "anchor")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func triggerRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "trigger")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func discontinuityRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "discontinuity")
            #expect(records.example.count == 2)
            #expect(records.built == records.example)
        }

        @Test func dispatchRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "dispatch")
            #expect(records.example.count == 4)
            #expect(records.built == records.example)
        }

        @Test func outcomeRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "outcome")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func midiCaptureRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "midiCapture")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func generationRecordEqualsTheExampleRecord() throws {
            let records = try timelineRecords(kind: "generation")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
        }

        @Test func readinessRecordsEqualTheExampleRecords() throws {
            let records = try timelineRecords(kind: "readiness")
            #expect(records.example.count == 3)
            #expect(records.built == records.example)
        }

        @Test func exportRecordEqualsTheExampleRecordFromASyntheticSMFResult() throws {
            let records = try timelineRecords(kind: "export")
            #expect(records.example.count == 1)
            #expect(records.built == records.example)
            let record = try #require(exampleTimeline().last)
            #expect(record["smfFormat"] as? Int == 1 && record["division"] as? Int == 960)
            #expect(record["lossless"] as? Bool == false)
            #expect(record["losses"] as? [String: Int] == ["passesOverlaid": 2])
        }

        @Test func eachTriggerHasItsOutcomeLaterInTheBuiltEntriesAndTheExample() throws {
            let expected = ["trg.1:2>8", "trg.2:11>14", "trg.3:20>21"]
            #expect(try triggerChains(builtRecords(Inputs.timelineEntries())) == expected)
            #expect(try triggerChains(exampleTimeline()) == expected)
        }

        @Test func theLocateBumpsTheTransportAndTheNextAnchorFollowsIt() throws {
            let built = try builtRecords(Inputs.timelineEntries())
            try #require(built.count == 23)
            let generation = built[11]
            #expect(generation["counter"] as? String == "transport/mus.main")
            #expect(generation["from"] as? Int == 1 && generation["to"] as? Int == 2)
            #expect(generation["reason"] as? String == "locate" && generation["musicalMap"] == nil)
            let anchor = built[16]
            #expect(anchor["transport"] as? Int == 2 && anchor["musicalTicks"] as? Int == 61_440)
            #expect(built[12]["type"] as? String == "locate" && built[13]["reason"] as? String == "transport")
        }

        @Test func theLoopWrapIsFollowedByTheLoopIterationOneAnchorAndThreeOrderedDispatches() throws {
            let built = try builtRecords(Inputs.timelineEntries())
            try #require(built.count == 23)
            #expect(built[2]["type"] as? String == "loopWrap" && built[2]["frame"] as? Int == 192_000)
            #expect(built[3]["kind"] as? String == "anchor" && built[3]["loopIteration"] as? Int == 1)
            #expect(built[4...6].map { $0["lane"] as? String } == ["release", "state", "content"])
            #expect(built[4...6].allSatisfy { $0["kind"] as? String == "dispatch" && $0["frame"] as? Int == 192_000 })
        }

        @Test func theRawExampleWritesLoopIterationZeroOnSeq1And17AndOneOnSeq4Only() throws {
            let written = try rawTimeline().compactMap { record -> String? in
                guard let value = record["loopIteration"] else { return nil }
                return "\(record["seq"] as? Int ?? 0):\(record["kind"] as? String ?? ""):\(value)"
            }
            #expect(written == ["1:anchor:0", "4:anchor:1", "17:anchor:0"])
        }

        @Test func theNormalizationRemovesTheZeroOnSeq1And17AndKeepsTheOneOnSeq4() throws {
            let raw = try rawTimeline()
            let after = try exampleTimeline()
            try #require(after.count == 23)
            try #require(raw.count == 23)
            for (before, now) in zip(raw, after) {
                let seq = before["seq"] as? Int ?? 0
                if seq == 1 || seq == 17 {
                    #expect(now["loopIteration"] == nil, "seq \(seq)")
                    #expect(Set(now.keys) == Set(before.keys).subtracting(["loopIteration"]), "seq \(seq)")
                } else {
                    #expect(try canonical(now) == canonical(before), "seq \(seq)")
                }
            }
            #expect(after[3]["loopIteration"] as? Int == 1)
            let rest = { (object: [String: Any]) in try canonical(object.filter { $0.key != "timeline" }) }
            #expect(try rest(normalizedExample()) == rest(exampleObject()))
        }

        @Test func theNormalizationLeavesNonZeroOtherKindAndNonNumberValuesAlone() throws {
            let object = try #require(try parse(Data(normalizationCase.utf8)) as? [String: Any])
            let records = try #require(normalized(object)["timeline"] as? [[String: Any]])
            try #require(records.count == 5)
            #expect(records[0]["loopIteration"] as? Int == 2)
            #expect(records[1]["loopIteration"] == nil && records[1]["kind"] as? String == "anchor")
            #expect(records[2]["loopIteration"] as? Int == 0)
            #expect(records[3]["loopIteration"] as? Bool == false)
            #expect(records[4].count == 2)
            #expect(normalized(object)["loopIteration"] as? Int == 0)
        }

        @Test func theBuilderOmitsLoopIterationForAZeroStampAndWritesItForOne() throws {
            let built = try builtRecords(Inputs.timelineEntries())
            try #require(built.count == 23)
            #expect(built[0]["kind"] as? String == "anchor" && built[0]["loopIteration"] == nil)
            #expect(built[3]["loopIteration"] as? Int == 1)
            #expect(built[16]["kind"] as? String == "anchor" && built[16]["loopIteration"] == nil)
        }

        @Test func aBuilderThatWroteAZeroLoopIterationWouldStillBeCaught() throws {
            var zeroWriting = try builtRecords(Inputs.timelineEntries())
            for index in zeroWriting.indices where zeroWriting[index]["kind"] as? String == "anchor"
                && zeroWriting[index]["loopIteration"] == nil {
                zeroWriting[index]["loopIteration"] = 0
            }
            let written = try canonical(zeroWriting)
            #expect(written != (try exampleSection("timeline")))
            // What the normalization hides: such a builder would match the raw example exactly.
            #expect(written == (try canonical(rawTimeline())))
            var document = try normalizedExample()
            document["timeline"] = zeroWriting
            #expect(try canonical(document) != canonical(normalizedExample()))
        }

        @Test func wholeDocumentEqualsTheFiveBuilderSectionsAndTheSixExampleOnlyKeys() throws {
            let expected = try canonical(normalizedExample())
            #expect(try rebuiltDocument() == expected)
        }

        @Test func aChangedBuilderInputMakesTheDocumentDiffer() throws {
            let expected = try canonical(normalizedExample())
            #expect(try rebuiltDocument(loopEnd: 122_881) != expected)
            #expect(try rebuiltDocument(horizon: 192_257) != expected)
            #expect(try rebuiltDocument(passesOverlaid: 3) != expected)
            #expect(try canonical(builderBytes: Inputs.clocksRecord(loopEnd: 122_881).encodedJSON())
                != (try exampleSection("clocks")))
            #expect(try canonical(builderBytes: Inputs.timelineRecord(passesOverlaid: 3).encodedJSON())
                != (try exampleSection("timeline")))
        }
    }
}
