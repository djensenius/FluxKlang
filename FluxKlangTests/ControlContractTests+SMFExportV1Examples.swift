//
//  ControlContractTests+SMFExportV1Examples.swift
//  FluxKlangTests
//
//  The media contract v1 SMF `exportRecord` of examples 03, 04, 09 and 10 built from the real export (#548 SMF3),
//  and the record as a timeline entry. The goldens differ from the contract's records in exactly the two header
//  fields this export writes differently (format 0 at 15,360 ticks per quarter, not format 1 at 960) and, for
//  example 10, `timingQuantized`, which is 0 at that division.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixtures = ControlContractTests.TimelineV1Fixtures
private typealias Fixture = MIDICaptureFixture

private let smfID = ExportID(validated: "exp.smf")

/// One example: its log, streams and `seq`, the golden record and the contract's own record.
private struct ExampleCase {
    let label: String
    let log: MIDICaptureLog
    let streams: [StreamID]
    let seq: Int
    /// Python's `json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` of the example's
    /// record, then edited as the file header says; never the Swift encoder's output.
    let golden: String
    /// The example file's record as written (`<example> seq <n>`), keys sorted.
    let contract: String
    /// The fields the golden does not share with the contract.
    let differing: [String]
}

/// Example 04: a pad capture after a tempo edit's second anchor, as `MIDICaptureExportTests+V1Capture.swift` builds it.
private func example04Log() throws -> MIDICaptureLog {
    let padsIn = StreamID(validated: "str.pads-in")
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

private func cases() throws -> [ExampleCase] {
    [ExampleCase(
        label: "example 03 seq 23", log: try Fixture.example03(), streams: [Fixture.keysIn], seq: 23,
        golden: #"{"division":15360,"exportId":"exp.smf","format":"smf","kind":"export","#
            + #""losses":{"passesOverlaid":2},"lossless":false,"seq":23,"smfFormat":0,"streams":["str.keys-in"]}"#,
        contract: #"{"division":960,"exportId":"exp.smf","format":"smf","kind":"export","#
            + #""losses":{"passesOverlaid":2},"lossless":false,"seq":23,"smfFormat":1,"streams":["str.keys-in"]}"#,
        differing: ["smfFormat", "division"]),
     ExampleCase(
        label: "example 04 seq 13", log: try example04Log(), streams: [StreamID(validated: "str.pads-in")], seq: 13,
        golden: #"{"division":15360,"exportId":"exp.smf","format":"smf","kind":"export","losses":{},"#
            + #""lossless":true,"seq":13,"smfFormat":0,"streams":["str.pads-in"]}"#,
        contract: #"{"division":960,"exportId":"exp.smf","format":"smf","kind":"export","losses":{},"#
            + #""lossless":true,"seq":13,"smfFormat":1,"streams":["str.pads-in"]}"#,
        differing: ["smfFormat", "division"]),
     ExampleCase(
        label: "example 09 seq 11", log: try Fixture.example09Captures(), streams: [Fixture.keysA, Fixture.keysB],
        seq: 11,
        golden: #"{"division":15360,"exportId":"exp.smf","format":"smf","kind":"export","losses":{},"#
            + #""lossless":true,"seq":11,"smfFormat":0,"streams":["str.keys-a","str.keys-b"]}"#,
        contract: #"{"division":960,"exportId":"exp.smf","format":"smf","kind":"export","losses":{},"#
            + #""lossless":true,"seq":11,"smfFormat":1,"streams":["str.keys-a","str.keys-b"]}"#,
        differing: ["smfFormat", "division"]),
     ExampleCase(
        label: "example 10 seq 12", log: try Fixture.example10(),
        streams: [Fixture.synth, Fixture.legacy, Fixture.unknown], seq: 12,
        golden: #"{"division":15360,"exportId":"exp.smf","format":"smf","kind":"export","#
            + #""losses":{"attributeDropped":1,"fidelityUnverified":1,"noteOnVelocityRemapped":1,"#
            + #""perNoteDropped":1,"umpOnlyDropped":1,"valueDownscaled":1,"velocityDownscaled":2},"#
            + #""lossless":false,"seq":12,"smfFormat":0,"streams":["str.synth","str.synth-legacy","#
            + #""str.synth-unknown"]}"#,
        contract: #"{"division":960,"exportId":"exp.smf","format":"smf","kind":"export","#
            + #""losses":{"attributeDropped":1,"fidelityUnverified":1,"noteOnVelocityRemapped":1,"#
            + #""perNoteDropped":1,"timingQuantized":1,"umpOnlyDropped":1,"valueDownscaled":1,"#
            + #""velocityDownscaled":2},"lossless":false,"seq":12,"smfFormat":1,"streams":["str.synth","#
            + #""str.synth-legacy","str.synth-unknown"]}"#,
        differing: ["smfFormat", "division", "timingQuantized"])]
}

/// `json` as an object with `keys` removed, at the top level and from `losses`.
private func stripped(_ json: String, _ keys: [String]) throws -> NSDictionary {
    var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    var losses = try #require(object["losses"] as? [String: Any])
    for key in keys {
        object[key] = nil
        losses[key] = nil
    }
    object["losses"] = losses
    return object as NSDictionary
}

/// A record over a synthetic header-only file, for the timeline tests.
private func synthetic(seq: Int, id: ExportID = smfID) throws -> TimelineV1Entry {
    let bytes: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x3C, 0]
    let file = SMFWriteResult(bytes: bytes, losses: SMFExportLossReport(losses: [:]), reorderedItems: 0)
    return .smfExport(try SMFExportV1Record.make(file, streams: [Fixture.keysA], exportID: id, seq: seq))
}

extension ControlContractTests {
    struct SMFExportV1Examples {
        @Test func theFourExamplesBuildTheirGoldenRecordsFromTheRealExport() throws {
            let all = try cases()
            try #require(all.count == 4)
            for example in all {
                let export = try CaptureClipExport.make(from: example.log, streams: example.streams, lengthTicks: nil)
                let file = export.smf()
                #expect(Array(file.bytes.prefix(14)) == [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x3C, 0x00],
                        "\(example.label)")
                let record = try SMFExportV1Record.make(file, streams: example.streams, exportID: smfID,
                                                         seq: example.seq)
                let written = try #require(String(data: record.encodedJSON(), encoding: .utf8))
                #expect(written == example.golden, "\(example.label)")
                #expect(record.losses == file.losses.losses, "\(example.label)")
                #expect(record.smfFormat == 0 && record.division == 15_360, "\(example.label)")
            }
        }

        @Test func theGoldensDifferFromTheContractsRecordsOnlyInTheDocumentedFields() throws {
            for example in try cases() {
                #expect(try stripped(example.golden, example.differing)
                    == stripped(example.contract, example.differing), "\(example.label)")
                #expect(try stripped(example.golden, []) != stripped(example.contract, []), "\(example.label)")
            }
        }

        @Test func example10ReportsNoTimingQuantizedAtThisDivision() throws {
            let all = try cases()
            let example = try #require(all.last)
            let export = try CaptureClipExport.make(from: example.log, streams: example.streams, lengthTicks: nil)
            let record = try SMFExportV1Record.make(export.smf(), streams: example.streams, exportID: smfID, seq: 12)
            #expect(record.losses[.timingQuantized] == nil && record.losses.count == 7 && !record.lossless)
        }

        @Test func timelineEntryExposesTheRecordsSeqAndKind() throws {
            let entry = try synthetic(seq: 7)
            #expect(entry.seq == 7 && entry.kind == "export")
            let written = try #require(String(data: Fixtures.payloadJSON(entry), encoding: .utf8))
            #expect(written == #"{"division":15360,"exportId":"exp.smf","format":"smf","kind":"export","#
                + #""losses":{},"lossless":true,"seq":7,"smfFormat":0,"streams":["str.keys-a"]}"#)
        }

        @Test func aTimelineOfSMFExportsEncodesAsItsJoinedRecords() throws {
            let entries = [try synthetic(seq: 1), try synthetic(seq: 2, id: ExportID(validated: "exp.smf2"))]
            let record = try TimelineV1Record.make(entries)
            #expect(try record.encodedJSON() == Fixtures.joined(entries))
            let text = try Fixtures.json(record)
            #expect(text.hasPrefix(#"[{"division":15360,"exportId":"exp.smf""#) && text.hasSuffix("}]"))
            #expect(text.contains(#""seq":2"#))
        }

        @Test func aRepeatedExportIDIsRefusedAcrossBothFormats() throws {
            let twice = [try synthetic(seq: 1), try synthetic(seq: 2)]
            #expect(Fixtures.refusal(twice) == .duplicateExportID(smfID))
            let nativeFirst = [try Fixtures.export(1, id: smfID), try synthetic(seq: 2)]
            #expect(Fixtures.refusal(nativeFirst) == .duplicateExportID(smfID))
            let smfFirst = [try synthetic(seq: 1), try Fixtures.export(2, id: smfID)]
            #expect(Fixtures.refusal(smfFirst) == .duplicateExportID(smfID))
        }

        @Test func distinctExportIDsAreAcceptedAcrossBothFormats() throws {
            let mixed = [try Fixtures.export(1), try synthetic(seq: 2)]
            #expect(Fixtures.refusal(mixed) == nil)
        }

        @Test func anSMFExportOutOfSequenceIsRefused() throws {
            #expect(Fixtures.refusal([try synthetic(seq: 2)]) == .sequenceBreak(index: 0, expected: 1, found: 2))
            let gapped = [try Fixtures.dispatch(1), try synthetic(seq: 3)]
            #expect(Fixtures.refusal(gapped) == .sequenceBreak(index: 1, expected: 2, found: 3))
        }
    }
}
