//
//  ControlContractTests+TimelineV1.swift
//  FluxKlangTests
//
//  The media contract v1 `timeline` array builder (#84 TRC1): the ten kinds against the example files byte for
//  byte, the array against its joined records, the kept order, the entry accessors, and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixtures = ControlContractTests.TimelineV1Fixtures

extension ControlContractTests {
    struct TimelineV1 {
        /// One record of each kind, renumbered to seq 1 through 10 (`<example> seq <original seq>`). The strings
        /// come from the example files through Python's
        /// `json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` after the renumbering,
        /// never from the Swift encoder.
        private static let goldens: [(label: String, json: String)] = [
            ("ex 01 seq 1 anchor",
             #"{"frame":0,"generation":1,"hostTicks":2400000000,"kind":"anchor","musicalTicks":0,"#
                + #""sampleClock":"smp.main","seq":1,"transport":1}"#),
            ("ex 01 seq 4 generation",
             #"{"counter":"sampleClock/smp.main","from":1,"kind":"generation","nominalRate":96000,"#
                + #""reason":"rateChange","seq":2,"to":2}"#),
            ("ex 04 seq 2 trigger",
             #"{"actionId":"act.backing","horizonFrame":1256,"kind":"trigger","originHostTicks":2400500000,"#
                + #""requires":{"context/ctx.main":1,"sampleClock/smp.main":1,"transport/mus.main":1},"seq":3,"#
                + #""triggerId":"trg.1"}"#),
            ("ex 04 seq 3 outcome",
             #"{"assignedFrame":96000,"frame":96000,"kind":"outcome","musicalMap":1,"result":"fired","seq":4,"#
                + #""triggerId":"trg.1"}"#),
            ("ex 04 seq 8 readiness",
             #"{"actionId":"act.stretch","from":"unprepared","kind":"readiness","seq":5,"to":"preparing"}"#),
            ("ex 01 seq 7 discontinuity",
             #"{"frame":0,"generation":2,"hostTicks":2490000000,"kind":"discontinuity","previousFrame":144000,"#
                + #""sampleClock":"smp.main","seq":6,"type":"clockRestart"}"#),
            ("ex 01 seq 3 dispatch",
             #"{"event":"bed loop block","frame":120000,"kind":"dispatch","lane":"content","seq":7,"#
                + #""stream":"str.bed","streamSeq":41}"#),
            ("ex 09 seq 2 midiCapture",
             #"{"effective":"midi1","endpointProtocol":"midi1","frame":24000,"hostTicks":2412000000,"#
                + #""kind":"midiCapture","musicalTicks":2560,"portProtocol":"midi1","seq":8,"#
                + #""stream":"str.keys-a","translatedBy":"none","ump":["0x20903C64"]}"#),
            ("ex 08 seq 8 take",
             #"{"droppedFrames":1536,"inputLatency":{"measuredFrames":null,"reportedFrames":312},"kind":"take","#
                + #""note":"Reported latency is not measured latency; no loopback measurement was made.","#
                + #""segments":[{"fileFrameStart":0,"frames":960000,"generation":1,"paddedFrames":1024,"#
                + #""sampleClock":"smp.main","startFrame":0,"startOffsetNs":0},{"fileFrameStart":960000,"#
                + #""frames":480000,"generation":2,"paddedFrames":512,"sampleClock":"smp.main","startFrame":0,"#
                + #""startOffsetNs":20833333333}],"seq":9,"stopReason":"diskFull","stream":"str.take-in","#
                + #""takeId":"tk.1"}"#),
            ("ex 10 seq 11 export",
             #"{"exportId":"exp.ump","format":"nativeUmp","kind":"export","losses":{},"lossless":true,"#
                + #""offsetsNs":[104167,250000000,500000000,750000000,1000000000,1250000000,2000000000],"#
                + #""origin":{"frame":24000,"generation":1,"sampleClock":"smp.main"},"seq":10,"#
                + #""streams":["str.synth"]}"#)
        ]

        private static let kinds = ["anchor", "generation", "trigger", "outcome", "readiness", "discontinuity",
                                    "dispatch", "midiCapture", "take", "export"]

        @Test func timelineV1RecordEncodesTheTenKindsExactly() throws {
            let entries = try Fixtures.tenKinds()
            try #require(entries.count == Self.goldens.count)
            for (entry, golden) in zip(entries, Self.goldens) {
                let data = try ContractCoding.makeEncoder().encode(entry)
                #expect(String(data: data, encoding: .utf8) == golden.json, "\(golden.label)")
            }
            let record = try TimelineV1Record.make(entries)
            #expect(try Fixtures.json(record) == "[" + Self.goldens.map(\.json).joined(separator: ",") + "]")
        }

        @Test func timelineV1RecordEqualsItsJoinedRecordsByteForByte() throws {
            let timelines: [(label: String, entries: [TimelineV1Entry])] = [
                ("ten kinds", try Fixtures.tenKinds()),
                ("one entry", [try Fixtures.anchor(1)]),
                ("100 dispatches", try Fixtures.dispatches(100))
            ]
            for timeline in timelines {
                let record = try TimelineV1Record.make(timeline.entries)
                #expect(try record.encodedJSON() == Fixtures.joined(timeline.entries), "\(timeline.label)")
                #expect(record.entries == timeline.entries, "\(timeline.label)")
            }
            #expect(timelines.map(\.entries.count) == [10, 1, 100])
        }

        @Test func timelineV1RecordKeepsTheCallersOrderAndNeverSorts() throws {
            let anchor = try Fixtures.anchor(1), dispatch = try Fixtures.dispatch(2)
            let swappedAnchor = try Fixtures.anchor(2), swappedDispatch = try Fixtures.dispatch(1)
            let first = try TimelineV1Record.make([anchor, dispatch])
            let second = try TimelineV1Record.make([swappedDispatch, swappedAnchor])
            #expect(first != second)
            #expect(try first.encodedJSON() != second.encodedJSON())
            #expect(first.entries.map(\.kind) == ["anchor", "dispatch"])
            #expect(second.entries.map(\.kind) == ["dispatch", "anchor"])
            #expect(try Fixtures.json(second).hasPrefix(#"[{"event":"bed loop block""#))
            let ten = try TimelineV1Record.make(Fixtures.tenKinds())
            #expect(ten.entries.map(\.kind) == Self.kinds)
        }

        @Test func timelineV1EntryReturnsTheWrappedRecordsSeqAndKind() throws {
            for first in [1, 41] {
                let entries = try Fixtures.tenKinds(from: first)
                try #require(entries.count == Self.kinds.count)
                #expect(entries.map(\.seq) == Array(first...(first + 9)))
                #expect(entries.map(\.kind) == Self.kinds)
            }
        }

        @Test func timelineV1RecordIsEqualHashableAndDeterministic() throws {
            let record = try TimelineV1Record.make(Fixtures.tenKinds())
            let again = try TimelineV1Record.make(Fixtures.tenKinds())
            #expect(record == again && record.hashValue == again.hashValue)
            #expect(try record.encodedJSON() == record.encodedJSON())
            #expect(try record.encodedJSON() == again.encodedJSON())
            var other = try Fixtures.tenKinds()
            try #require(other.count == 10)
            other[2] = try Fixtures.trigger(3, id: "trg.2")
            let different = try TimelineV1Record.make(other)
            #expect(record != different)
            #expect(try record.encodedJSON() != different.encodedJSON())
        }
    }
}
