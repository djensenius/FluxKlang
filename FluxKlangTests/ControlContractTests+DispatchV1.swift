//
//  ControlContractTests+DispatchV1.swift
//  FluxKlangTests
//
//  The media contract v1 `dispatchRecord` builder (#107 DPR1): golden example records byte for byte, the
//  numeric and text bounds, the refusal order, the trace rules it leaves to the checker, the lane order against
//  the kernel's `EventLane`, the record's shape, and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = DispatchV1RecordRefusal

private let bedStream = StreamID(validated: "str.bed")
private let verseStream = StreamID(validated: "str.verse")
private let stateStream = StreamID(validated: "str.state")
private let clockStream = StreamID(validated: "str.clock")
private let lanesStream = StreamID(validated: "str.lanes")

private func makeDispatch(seq: Int = 2, frame: Int64 = 5, lane: DispatchV1Lane = .state,
                          stream: StreamID = bedStream, streamSeq: UInt64 = 3, event: String = "e",
                          note: String? = nil) throws(Refusal) -> DispatchV1Record {
    try DispatchV1Record.make(seq: seq, frame: frame, lane: lane, stream: stream, streamSeq: streamSeq,
                              event: event, note: note)
}

private func dispatchRefusal(seq: Int = 2, frame: Int64 = 5, lane: DispatchV1Lane = .state,
                             stream: StreamID = bedStream, streamSeq: UInt64 = 3, event: String = "e",
                             note: String? = nil) -> Refusal? {
    do {
        _ = try makeDispatch(seq: seq, frame: frame, lane: lane, stream: stream, streamSeq: streamSeq,
                             event: event, note: note)
        return nil
    } catch {
        return error
    }
}

private func dispatchObject(_ record: DispatchV1Record) throws -> [String: Any] {
    let decoded = try JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any]
    return try #require(decoded)
}

/// A golden `dispatchRecord`, keys sorted, compact. The first six rows are the example records (`<example> seq <n>`);
/// their strings come from the example files through Python's
/// `json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`, never from the Swift encoder.
/// The other six are not in the examples (none has a `transport` record or a `note`); they were validated against
/// `$defs.dispatchRecord` with the checker's `validate`. Together they cover every lane.
private struct GoldenDispatch {
    let label: String
    let seq: Int
    let frame: Int64
    let lane: DispatchV1Lane
    let stream: StreamID
    let streamSeq: UInt64
    let event: String
    let note: String?
    let json: String

    init(_ label: String, seq: Int, frame: Int64, lane: DispatchV1Lane, stream: StreamID, streamSeq: UInt64,
         event: String, note: String? = nil, _ json: String) {
        (self.label, self.seq, self.frame, self.lane) = (label, seq, frame, lane)
        (self.stream, self.streamSeq, self.event) = (stream, streamSeq, event)
        (self.note, self.json) = (note, json)
    }

    func record() throws(Refusal) -> DispatchV1Record {
        try makeDispatch(seq: seq, frame: frame, lane: lane, stream: stream, streamSeq: streamSeq, event: event,
                         note: note)
    }
}

private let goldenDispatchRecords: [GoldenDispatch] = [
    .init("01 seq 3", seq: 3, frame: 120_000, lane: .content, stream: bedStream, streamSeq: 41,
          event: "bed loop block",
          #"{"event":"bed loop block","frame":120000,"kind":"dispatch","lane":"content","seq":3,"#
            + #""stream":"str.bed","streamSeq":41}"#),
    .init("01 seq 9", seq: 9, frame: 100, lane: .content, stream: bedStream, streamSeq: 42,
          event: "bed loop block",
          #"{"event":"bed loop block","frame":100,"kind":"dispatch","lane":"content","seq":9,"#
            + #""stream":"str.bed","streamSeq":42}"#),
    .init("03 seq 5", seq: 5, frame: 192_000, lane: .release, stream: verseStream, streamSeq: 41,
          event: "noteOff 60 (owned note, releaseAtWrap)",
          #"{"event":"noteOff 60 (owned note, releaseAtWrap)","frame":192000,"kind":"dispatch","#
            + #""lane":"release","seq":5,"stream":"str.verse","streamSeq":41}"#),
    .init("03 seq 6", seq: 6, frame: 192_000, lane: .state, stream: stateStream, streamSeq: 7,
          event: "program 12 (prepared state recall)",
          #"{"event":"program 12 (prepared state recall)","frame":192000,"kind":"dispatch","lane":"state","#
            + #""seq":6,"stream":"str.state","streamSeq":7}"#),
    .init("03 seq 7", seq: 7, frame: 192_000, lane: .content, stream: verseStream, streamSeq: 42,
          event: "noteOn 60",
          #"{"event":"noteOn 60","frame":192000,"kind":"dispatch","lane":"content","seq":7,"#
            + #""stream":"str.verse","streamSeq":42}"#),
    .init("03 seq 15", seq: 15, frame: 210_000, lane: .release, stream: verseStream, streamSeq: 43,
          event: "all owned notes off (locate)",
          #"{"event":"all owned notes off (locate)","frame":210000,"kind":"dispatch","lane":"release","#
            + #""seq":15,"stream":"str.verse","streamSeq":43}"#),
    // Not examples. A `transport` record, and a `note` on a `content` record (`/` stays unescaped).
    .init("transport", seq: 4, frame: 96_000, lane: .transport, stream: clockStream, streamSeq: 12,
          event: "clockPulse",
          #"{"event":"clockPulse","frame":96000,"kind":"dispatch","lane":"transport","seq":4,"#
            + #""stream":"str.clock","streamSeq":12}"#),
    .init("note", seq: 8, frame: 288_000, lane: .content, stream: verseStream, streamSeq: 44, event: "noteOn 62",
          note: "late/joined",
          #"{"event":"noteOn 62","frame":288000,"kind":"dispatch","lane":"content","note":"late/joined","#
            + #""seq":8,"stream":"str.verse","streamSeq":44}"#),
    // Every lane once, on one stream at one frame, in rank order.
    .init("lane release", seq: 1, frame: 0, lane: .release, stream: lanesStream, streamSeq: 1, event: "noteOff 60",
          #"{"event":"noteOff 60","frame":0,"kind":"dispatch","lane":"release","seq":1,"stream":"str.lanes","#
            + #""streamSeq":1}"#),
    .init("lane transport", seq: 2, frame: 0, lane: .transport, stream: lanesStream, streamSeq: 2,
          event: "clockPulse",
          #"{"event":"clockPulse","frame":0,"kind":"dispatch","lane":"transport","seq":2,"stream":"str.lanes","#
            + #""streamSeq":2}"#),
    .init("lane state", seq: 3, frame: 0, lane: .state, stream: lanesStream, streamSeq: 3, event: "program 12",
          #"{"event":"program 12","frame":0,"kind":"dispatch","lane":"state","seq":3,"stream":"str.lanes","#
            + #""streamSeq":3}"#),
    .init("lane content", seq: 4, frame: 0, lane: .content, stream: lanesStream, streamSeq: 4, event: "noteOn 60",
          #"{"event":"noteOn 60","frame":0,"kind":"dispatch","lane":"content","seq":4,"stream":"str.lanes","#
            + #""streamSeq":4}"#)
]

extension ControlContractTests {
    struct DispatchV1 {
        @Test func dispatchV1RecordEncodesTheGoldenDispatchRecordsExactly() throws {
            #expect(goldenDispatchRecords.count == 12) // 6 example records + 6 extra rows
            #expect(Set(goldenDispatchRecords.map(\.lane)) == Set(DispatchV1Lane.allCases))
            for golden in goldenDispatchRecords {
                let record = try golden.record()
                let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
                #expect(json == golden.json, "\(golden.label)")
                #expect(record.seq == golden.seq && record.frame == golden.frame, "\(golden.label)")
                #expect(record.lane == golden.lane && record.stream == golden.stream, "\(golden.label)")
                #expect(record.streamSeq == golden.streamSeq, "\(golden.label)")
                #expect(record.event == golden.event && record.note == golden.note, "\(golden.label)")
                let again = try golden.record()
                #expect(again == record, "\(golden.label)")
                #expect(try again.encodedJSON() == record.encodedJSON(), "\(golden.label)")
            }
        }

        /// `seq` up to `Int.max`, `frame` over the whole `Int64` range and a `streamSeq` up to `UInt64.max` (the
        /// schema sets no maximum) are written exactly: nothing is clamped or rounded.
        @Test func dispatchV1RecordWritesTheNumericExtremesExactly() throws {
            let frames: [(Int64, String)] = [(.min, "-9223372036854775808"), (0, "0"), (.max, "9223372036854775807")]
            for (frame, text) in frames {
                let record = try makeDispatch(seq: .max, frame: frame, lane: .content, streamSeq: .max)
                let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
                let expected = #"{"event":"e","frame":\#(text),"kind":"dispatch","lane":"content","#
                    + #""seq":9223372036854775807,"stream":"str.bed","streamSeq":18446744073709551615}"#
                #expect(json == expected, "\(frame)")
            }
            let smallest = try makeDispatch(seq: 1, frame: 0, lane: .release, streamSeq: 1)
            let json = try #require(String(data: smallest.encodedJSON(), encoding: .utf8))
            #expect(json == #"{"event":"e","frame":0,"kind":"dispatch","lane":"release","seq":1,"#
                        + #""stream":"str.bed","streamSeq":1}"#)
        }

        @Test func dispatchV1RecordRefusesInOrderWithoutClampingOrRemapping() throws {
            let badStream = StreamID(validated: "Str.bed")
            // Every field bad: each refusal appears once the earlier ones are fixed.
            #expect(dispatchRefusal(seq: 0, stream: badStream, streamSeq: 0, event: "", note: "") == .invalidSeq(0))
            #expect(dispatchRefusal(stream: badStream, streamSeq: 0, event: "", note: "") == .invalidStream(badStream))
            #expect(dispatchRefusal(streamSeq: 0, event: "", note: "") == .invalidStreamSeq(0))
            #expect(dispatchRefusal(event: "", note: "") == .invalidEvent(bytes: 0))
            #expect(dispatchRefusal(note: "") == .invalidNote(bytes: 0))
            #expect(dispatchRefusal(note: "n") == nil)
            // Each adjacent pair on its own.
            #expect(dispatchRefusal(seq: 0, stream: badStream) == .invalidSeq(0))
            #expect(dispatchRefusal(stream: badStream, streamSeq: 0) == .invalidStream(badStream))
            #expect(dispatchRefusal(streamSeq: 0, event: " ") == .invalidStreamSeq(0))
            #expect(dispatchRefusal(event: " ", note: " ") == .invalidEvent(bytes: 1))
        }

        @Test func dispatchV1RecordRefusesASeqBelowOneAndAStreamSeqOfZero() throws {
            #expect(dispatchRefusal(seq: 0) == .invalidSeq(0))
            #expect(dispatchRefusal(seq: -1) == .invalidSeq(-1))
            #expect(dispatchRefusal(seq: Int.min) == .invalidSeq(Int.min))
            #expect(dispatchRefusal(seq: 1) == nil && dispatchRefusal(seq: Int.max) == nil)
            #expect(dispatchRefusal(streamSeq: 0) == .invalidStreamSeq(0))
            #expect(dispatchRefusal(streamSeq: 1) == nil && dispatchRefusal(streamSeq: UInt64.max) == nil)
            // `frame` and `lane` cannot be wrong by type: every value builds.
            for frame in [Int64.min, -1, 0, 1, Int64.max] {
                for lane in DispatchV1Lane.allCases {
                    #expect(dispatchRefusal(frame: frame, lane: lane) == nil, "\(frame) \(lane)")
                }
            }
        }

        @Test func dispatchV1RecordRefusesAStreamOutsideTheContractPattern() throws {
            // `ContractID` also admits upper case, `_` and `:`; the pattern needs a dot and a tail after it.
            let refused: [StaticString] = [
                "Str.bed", "STR.BED", "sTr.bed", "str.Bed", "str_bed", "s_r.bed", "str.be_d", "str:bed", "s:r.bed",
                "str.be:d", "strbed", "str-bed", "str.", "s", "1tr.bed", "-tr.bed", ".bed"
            ]
            for raw in refused {
                let stream = StreamID(validated: raw)
                #expect(dispatchRefusal(stream: stream) == .invalidStream(stream), "\(raw)")
            }
            for raw: StaticString in ["a.b", "str.a.b", "str.0", "s-1.2-3", "str.bed"] {
                #expect(dispatchRefusal(stream: StreamID(validated: raw)) == nil, "\(raw)")
            }
            // The longest ID `ContractID` allows (128 bytes) builds and is written whole.
            let longest = try StreamID("s." + String(repeating: "a", count: StreamID.maximumLength - 2))
            #expect(longest.rawValue.utf8.count == 128 && dispatchRefusal(stream: longest) == nil)
            let object = try dispatchObject(makeDispatch(stream: longest))
            #expect(object["stream"] as? String == longest.rawValue)
            // An empty stream ID never reaches the builder: `ContractID` cannot hold one, so there is no case.
            #expect(throws: ContractIDError.invalidLength(0)) { _ = try StreamID("") }
            #expect(StreamID(rawValue: "") == nil)
        }

        @Test func dispatchV1EventAndNoteFollowTheTakeNoteRules() throws {
            let limit = DispatchV1Record.maximumNoteBytes
            #expect(limit == MediaContractV1Note.maximumBytes && limit == 256)
            let ascii = String(repeating: "a", count: limit)
            let accented = String(repeating: "é", count: limit / 2)
            let emoji = String(repeating: "😀", count: limit / 4)
            let cases: [(String, Int?)] = [
                ("", 0), (" ", 1), ("\t\n", 2), (" \n\t", 3), ("\u{00A0}", 2), (ascii + "a", limit + 1),
                (accented + "é", limit + 2), (emoji + "😀", limit + 4),
                (ascii, nil), (accented, nil), (emoji, nil), ("x", nil), (" x ", nil), ("noteOn 60", nil)
            ]
            for (text, bytes) in cases {
                let eventRefusal = dispatchRefusal(event: text)
                let noteRefusal = dispatchRefusal(note: text)
                if let bytes {
                    #expect(eventRefusal == .invalidEvent(bytes: bytes), "\(bytes)")
                    #expect(noteRefusal == .invalidNote(bytes: bytes), "\(bytes)")
                } else {
                    #expect(eventRefusal == nil && noteRefusal == nil, "\(text.utf8.count)")
                }
            }
            // Accepted text is written verbatim: not trimmed, truncated or remapped.
            let tricky = "a \"b\" \\ c/d é 😀\n\u{7}"
            let record = try makeDispatch(event: " x ", note: tricky)
            #expect(record.event == " x " && record.note == tricky)
            let object = try dispatchObject(record)
            #expect(object["event"] as? String == " x " && object["note"] as? String == tricky)
            let longest = try dispatchObject(makeDispatch(event: accented, note: ascii))
            #expect(longest["event"] as? String == accented && longest["note"] as? String == ascii)
            // Text is never normalized: canonically equal text gives equal records but different bytes.
            let (composed, decomposed) = ("\u{00E9}", "e\u{0301}")
            #expect(try makeDispatch(event: composed) == makeDispatch(event: decomposed))
            #expect(try makeDispatch(event: composed).encodedJSON() != makeDispatch(event: decomposed).encodedJSON())
            #expect(try makeDispatch(note: composed) == makeDispatch(note: decomposed))
            #expect(try makeDispatch(note: composed).encodedJSON() != makeDispatch(note: decomposed).encodedJSON())
        }

        /// The builder checks one record. That a stream is declared, that records follow the dispatch order
        /// `(frame, lane, streamOrdinal, streamSeq)` and that `streamSeq` rises within a stream need the whole
        /// trace, so they stay with the checker (`on_dispatch`) and the trace assembler. Each record below breaks
        /// one of those rules and still builds: the checker refuses the trace it sits in, not this builder the record.
        @Test func dispatchV1BuilderLeavesTheTraceRulesToTheChecker() throws {
            // "dispatch names a declared stream": a builder holds no list of declared streams.
            let undeclared = try makeDispatch(stream: StreamID("str.undeclared"))
            #expect(undeclared.stream.rawValue == "str.undeclared")
            // "stream order is preserved within a stream": `streamSeq` going backwards, or standing still.
            let first = try makeDispatch(seq: 1, frame: 10, lane: .content, streamSeq: 42)
            let backwards = try makeDispatch(seq: 2, frame: 20, lane: .content, streamSeq: 41)
            let repeated = try makeDispatch(seq: 3, frame: 30, lane: .content, streamSeq: 42)
            #expect(first.streamSeq == 42 && backwards.streamSeq == 41 && repeated.streamSeq == 42)
            // "dispatch order must follow (frame, lane, streamOrdinal, streamSeq)": a `release` record after a
            // `content` record at the same frame, and a frame that goes back.
            let content = try makeDispatch(seq: 1, frame: 100, lane: .content, streamSeq: 1)
            let release = try makeDispatch(seq: 2, frame: 100, lane: .release, streamSeq: 2)
            let earlier = try makeDispatch(seq: 3, frame: 99, lane: .content, streamSeq: 3)
            #expect(content.frame == release.frame && content.lane == .content && release.lane == .release)
            #expect(earlier.frame < release.frame)
            // Nothing is remembered between calls: the same inputs build the same record again.
            #expect(try makeDispatch(seq: 2, frame: 20, lane: .content, streamSeq: 41) == backwards)
        }

        /// `DispatchV1Lane` against the kernel's `EventLane` and the checker's `LANES` table (media-contract.md
        /// §6.5 ranks): the same four lanes, in rank order and spelled alike, so that a fifth kernel lane or a
        /// reorder fails here. `Shared` has no conversion between the two types on purpose.
        @Test func dispatchV1LanesMatchTheKernelEventLanesInRankOrder() throws {
            let kernel = (UInt8(0)...3).compactMap { EventLane(rawValue: $0) }
            let spelled = kernel.map { String(describing: $0) }
            #expect(kernel.map(\.rawValue) == [0, 1, 2, 3])
            #expect(EventLane(rawValue: 4) == nil)
            #expect(DispatchV1Lane.allCases.map(\.rawValue) == spelled)
            #expect(spelled == ["release", "transport", "state", "content"])
            let checker: [String: Int] = ["release": 0, "transport": 1, "state": 2, "content": 3]
            #expect(Set(checker.keys) == Set(spelled))
            for (rank, lane) in DispatchV1Lane.allCases.enumerated() {
                #expect(checker[lane.rawValue] == rank, "\(lane)")
            }
        }

        /// Exactly the schema's keys (`additionalProperties` is false), `note` only when given, `kind` constant,
        /// and no field that only another record kind has (derived from the schema's other `$defs.*Record`).
        @Test func dispatchV1RecordWritesExactlyTheSchemaFields() throws {
            let required: Set<String> = ["seq", "kind", "frame", "lane", "stream", "streamSeq", "event"]
            let foreign: Set<String> = [
                "actionId", "assignedFrame", "counter", "division", "droppedFrames", "effective", "endpointProtocol",
                "exportId", "format", "frames", "from", "generation", "horizonFrame", "hostTicks", "inputLatency",
                "loopIteration", "losses", "lossless", "meter", "musicalMap", "musicalTicks", "nominalRate",
                "offsetsNs", "origin", "originHostTicks", "portProtocol", "previousFrame", "reason", "requires",
                "result", "sampleClock", "segments", "smfFormat", "startOffsetFrames", "stopReason", "streams",
                "takeId", "target", "to", "translatedBy", "transport", "triggerId", "type", "ump", "verified"
            ]
            #expect(DispatchV1Record.kind == "dispatch")
            for lane in DispatchV1Lane.allCases {
                let plain = try dispatchObject(makeDispatch(lane: lane))
                #expect(Set(plain.keys) == required, "\(lane)")
                #expect(plain["kind"] as? String == "dispatch" && plain["lane"] as? String == lane.rawValue, "\(lane)")
                let noted = try dispatchObject(makeDispatch(lane: lane, note: "n"))
                #expect(Set(noted.keys) == required.union(["note"]), "\(lane)")
                #expect(noted["note"] as? String == "n", "\(lane)")
                #expect(Set(plain.keys).intersection(foreign) == [] && Set(noted.keys).intersection(foreign) == [])
            }
        }

        @Test func dispatchV1RecordIsDeterministicAndEveryFieldChangesTheBytes() throws {
            let base = try makeDispatch(note: "n")
            let bytes = try base.encodedJSON()
            for _ in 0..<20 {
                #expect(try base.encodedJSON() == bytes)
            }
            let same = try makeDispatch(note: "n")
            #expect(same == base && same.hashValue == base.hashValue)
            #expect(try same.encodedJSON() == bytes)
            // Changing any one field changes the record and what it encodes to.
            let variants: [DispatchV1Record] = try [
                makeDispatch(seq: 3, note: "n"), makeDispatch(frame: 6, note: "n"),
                makeDispatch(lane: .content, note: "n"), makeDispatch(stream: verseStream, note: "n"),
                makeDispatch(streamSeq: 4, note: "n"), makeDispatch(event: "f", note: "n"),
                makeDispatch(note: "m"), makeDispatch(note: nil)
            ]
            #expect(variants.count == 8)
            for variant in variants {
                #expect(variant != base)
                #expect(try variant.encodedJSON() != bytes)
            }
        }
    }
}
