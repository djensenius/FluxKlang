//
//  ControlContractTests+DiscontinuityV1.swift
//  FluxKlangTests
//
//  The media contract v1 `discontinuityRecord` builder for clock, transport and stream events (#109 DXR1):
//  golden example records byte for byte, the fields each type writes, the refusal order, the `frames` bounds,
//  the note rules, and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = DiscontinuityV1RecordRefusal
private typealias Event = DiscontinuityV1Record.Event

private let smpMain = ClockID(validated: "smp.main")
private let backing = StreamID(validated: "str.backing")

private func discontinuityRefusal(_ event: Event = .underrun(backing, frames: 512), clock: ClockID = smpMain,
                                  frame: Int64 = 0, seq: Int = 1, note: String? = nil) -> Refusal? {
    do {
        _ = try DiscontinuityV1Record.make(event, sampleClock: clock, generation: .initial, frame: frame, seq: seq,
                                           note: note)
        return nil
    } catch {
        return error
    }
}

private func keys(_ record: DiscontinuityV1Record) throws -> Set<String> {
    let decoded = try JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any]
    return Set(try #require(decoded).keys)
}

/// A golden `discontinuityRecord` from a media contract example (`<example> seq <n>`), keys sorted, compact;
/// the table pins all 8 example records of the types this builder covers.
private struct GoldenDiscontinuity {
    let label: String
    let event: Event
    let generation: Int
    let frame: Int64
    let seq: Int
    let note: String?
    let json: String

    init(_ label: String, _ event: Event, generation: Int, frame: Int64, seq: Int, note: String? = nil,
         _ json: String) {
        (self.label, self.event, self.generation, self.frame) = (label, event, generation, frame)
        (self.seq, self.note, self.json) = (seq, note, json)
    }
}

private let goldenDiscontinuityRecords: [GoldenDiscontinuity] = [
    .init("01 seq 7", .clockRestart(hostTicks: 2_490_000_000, previousFrame: 144_000), generation: 2, frame: 0,
          seq: 7,
          #"{"frame":0,"generation":2,"hostTicks":2490000000,"kind":"discontinuity","previousFrame":144000,"#
            + #""sampleClock":"smp.main","seq":7,"type":"clockRestart"}"#),
    .init("03 seq 3", .loopWrap, generation: 1, frame: 192_000, seq: 3,
          #"{"frame":192000,"generation":1,"kind":"discontinuity","sampleClock":"smp.main","seq":3,"#
            + #""type":"loopWrap"}"#),
    .init("03 seq 13", .locate, generation: 1, frame: 210_000, seq: 13,
          #"{"frame":210000,"generation":1,"kind":"discontinuity","sampleClock":"smp.main","seq":13,"#
            + #""type":"locate"}"#),
    .init("05 seq 4", .underrun(backing, frames: 512), generation: 1, frame: 150_000, seq: 4,
          #"{"frame":150000,"frames":512,"generation":1,"kind":"discontinuity","sampleClock":"smp.main","seq":4,"#
            + #""stream":"str.backing","type":"underrun"}"#),
    .init("05 seq 7", .sourceLost(backing), generation: 1, frame: 180_000, seq: 7, note: "volume unmounted",
          #"{"frame":180000,"generation":1,"kind":"discontinuity","note":"volume unmounted","#
            + #""sampleClock":"smp.main","seq":7,"stream":"str.backing","type":"sourceLost"}"#),
    .init("05 seq 11", .sourceRestored(backing), generation: 1, frame: 230_000, seq: 11,
          #"{"frame":230000,"generation":1,"kind":"discontinuity","sampleClock":"smp.main","seq":11,"#
            + #""stream":"str.backing","type":"sourceRestored"}"#),
    .init("08 seq 4", .clockRestart(hostTicks: 2_900_000_000, previousFrame: 960_000), generation: 2, frame: 0,
          seq: 4,
          #"{"frame":0,"generation":2,"hostTicks":2900000000,"kind":"discontinuity","previousFrame":960000,"#
            + #""sampleClock":"smp.main","seq":4,"type":"clockRestart"}"#),
    .init("09 seq 8", .clockRestart(hostTicks: 2_490_000_000, previousFrame: 150_000), generation: 2, frame: 0,
          seq: 8,
          #"{"frame":0,"generation":2,"hostTicks":2490000000,"kind":"discontinuity","previousFrame":150000,"#
            + #""sampleClock":"smp.main","seq":8,"type":"clockRestart"}"#)
]

extension ControlContractTests {
    struct DiscontinuityV1 {
        @Test func discontinuityV1RecordEncodesTheGoldenDiscontinuityRecordsExactly() throws {
            #expect(goldenDiscontinuityRecords.count == 8)
            for golden in goldenDiscontinuityRecords {
                let generation = try Generation(golden.generation)
                let record = try DiscontinuityV1Record.make(golden.event, sampleClock: smpMain, generation: generation,
                                                            frame: golden.frame, seq: golden.seq, note: golden.note)
                let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
                #expect(json == golden.json, "\(golden.label)")
                #expect(record.seq == golden.seq && record.event == golden.event, "\(golden.label)")
                #expect(record.generation == generation && record.frame == golden.frame, "\(golden.label)")
                #expect(record.sampleClock == smpMain && record.note == golden.note, "\(golden.label)")
                let again = try DiscontinuityV1Record.make(golden.event, sampleClock: smpMain, generation: generation,
                                                           frame: golden.frame, seq: golden.seq, note: golden.note)
                #expect(again == record, "\(golden.label)")
                #expect(try again.encodedJSON() == record.encodedJSON(), "\(golden.label)")
            }
        }

        /// `previousFrame` and `hostTicks` only on `clockRestart`, `frames` only on `underrun`, a stream only
        /// where §8.4 names one, `reason` never; schema extremes are written exactly.
        @Test func discontinuityV1RecordWritesExactlyEachTypesFields() throws {
            let common: Set<String> = ["seq", "kind", "type", "sampleClock", "generation", "frame"]
            let cases: [(Event, Set<String>)] = [
                (.clockRestart(hostTicks: 1, previousFrame: 2), ["hostTicks", "previousFrame"]),
                (.underrun(backing, frames: 1), ["frames", "stream"]),
                (.sourceLost(backing), ["stream"]), (.sourceRestored(backing), ["stream"]),
                (.locate, []), (.loopWrap, []), (.formatChange(backing), ["stream"])
            ]
            for (event, extra) in cases {
                let record = try DiscontinuityV1Record.make(event, sampleClock: smpMain, generation: .initial, frame: 5,
                                                            seq: 2)
                #expect(try keys(record) == common.union(extra), "\(event.type)")
                let noted = try DiscontinuityV1Record.make(event, sampleClock: smpMain, generation: .initial, frame: 5,
                                                           seq: 2, note: "n")
                #expect(try keys(noted) == common.union(extra).union(["note"]), "\(event.type)")
            }
            let types = cases.map(\.0.type)
            #expect(types == ["clockRestart", "underrun", "sourceLost", "sourceRestored", "locate", "loopWrap",
                              "formatChange"])
            let extreme = try DiscontinuityV1Record.make(
                .clockRestart(hostTicks: .max, previousFrame: .min), sampleClock: smpMain,
                generation: Generation(Generation.maximumValue), frame: .max, seq: .max)
            let json = try #require(String(data: extreme.encodedJSON(), encoding: .utf8))
            #expect(json == #"{"frame":9223372036854775807,"generation":9007199254740991,"#
                        + #""hostTicks":18446744073709551615,"kind":"discontinuity","#
                        + #""previousFrame":-9223372036854775808,"sampleClock":"smp.main","#
                        + #""seq":9223372036854775807,"type":"clockRestart"}"#)
        }

        @Test func discontinuityV1RecordRefusesInOrderWithoutClampingOrRemapping() throws {
            let badClock = ClockID(validated: "Smp.main")
            let badStream = StreamID(validated: "str_backing")
            // Every field bad: each refusal appears once the earlier ones are fixed.
            #expect(discontinuityRefusal(.underrun(badStream, frames: 0), clock: badClock, seq: 0, note: "")
                        == .invalidSeq(0))
            #expect(discontinuityRefusal(.underrun(badStream, frames: 0), clock: badClock, note: "")
                        == .invalidSampleClock(badClock))
            #expect(discontinuityRefusal(.underrun(badStream, frames: 0), note: "") == .invalidStream(badStream))
            #expect(discontinuityRefusal(.underrun(backing, frames: 0), note: "") == .framesOutOfRange(0))
            #expect(discontinuityRefusal(.underrun(backing, frames: 1), note: "") == .invalidNote(bytes: 0))
            #expect(discontinuityRefusal(.underrun(backing, frames: 1), note: "n") == nil)
        }

        @Test func discontinuityV1RecordRefusesASeqBelowOne() throws {
            #expect(discontinuityRefusal(seq: 0) == .invalidSeq(0))
            #expect(discontinuityRefusal(seq: -1) == .invalidSeq(-1))
            #expect(discontinuityRefusal(seq: Int.min) == .invalidSeq(Int.min))
            #expect(discontinuityRefusal(seq: 1) == nil && discontinuityRefusal(seq: Int.max) == nil)
        }

        @Test func discontinuityV1RecordRefusesASampleClockOutsideTheContractPattern() throws {
            for raw: StaticString in ["smp_main", "smp", "smp.", "1smp.a", "smp:1.a", "SMP.MAIN"] {
                let clock = ClockID(validated: raw)
                #expect(discontinuityRefusal(.locate, clock: clock) == .invalidSampleClock(clock), "\(raw)")
            }
        }

        @Test func discontinuityV1RecordRefusesAStreamOutsideTheContractPattern() throws {
            let stream = StreamID(validated: "Str.backing")
            let events: [Event] = [.underrun(stream, frames: 1), .sourceLost(stream), .sourceRestored(stream),
                                   .formatChange(stream)]
            for event in events {
                #expect(discontinuityRefusal(event) == .invalidStream(stream), "\(event.type)")
            }
        }

        @Test func discontinuityV1UnderrunFramesStayInTheSchemaRange() throws {
            let limit = DiscontinuityV1Record.maximumFrames
            #expect(limit == 4_294_967_295)
            for frames in [0, -1, Int64.min, limit + 1, Int64.max] {
                #expect(discontinuityRefusal(.underrun(backing, frames: frames)) == .framesOutOfRange(frames))
            }
            for frames in [1, limit] {
                let record = try DiscontinuityV1Record.make(.underrun(backing, frames: frames), sampleClock: smpMain,
                                                            generation: .initial, frame: 0, seq: 1)
                let decoded = try JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any]
                #expect(try #require(decoded)["frames"] as? Int64 == frames)
            }
        }

        @Test func discontinuityV1NoteFollowsTheTakeNoteRules() throws {
            let limit = DiscontinuityV1Record.maximumNoteBytes
            #expect(limit == RecordingTakeV1Record.maximumNoteBytes && limit == 256)
            let ascii = String(repeating: "a", count: limit)
            let accented = String(repeating: "é", count: limit / 2)
            let cases: [(String, Int?)] = [
                ("", 0), (" \n\t", 3), ("\u{00A0}", 2), (ascii + "a", limit + 1),
                (String(repeating: "é", count: limit / 2 + 1), limit + 2),
                (ascii, nil), (accented, nil), (" x ", nil), ("volume unmounted", nil)
            ]
            for (text, bytes) in cases {
                let refusal = discontinuityRefusal(.locate, note: text)
                if let bytes {
                    #expect(refusal == .invalidNote(bytes: bytes), "\(bytes)")
                } else {
                    #expect(refusal == nil, "\(text.utf8.count)")
                }
            }
            // Accepted text is written verbatim and never normalized: canonically equal notes give equal
            // records but different bytes.
            let padded = try DiscontinuityV1Record.make(.locate, sampleClock: smpMain, generation: .initial, frame: 0,
                                                        seq: 1, note: " x/y ")
            let decoded = try JSONSerialization.jsonObject(with: padded.encodedJSON()) as? [String: Any]
            #expect(try #require(decoded)["note"] as? String == " x/y ")
            let composed = try DiscontinuityV1Record.make(.locate, sampleClock: smpMain, generation: .initial,
                                                          frame: 0, seq: 1, note: "\u{00E9}")
            let decomposed = try DiscontinuityV1Record.make(.locate, sampleClock: smpMain, generation: .initial,
                                                            frame: 0, seq: 1, note: "e\u{0301}")
            #expect(composed == decomposed)
            #expect(try composed.encodedJSON() != decomposed.encodedJSON())
        }

        /// A take's `overflow` and `captureStopped` built directly encode example 08's records (seqs 2, 7, 9).
        @Test func discontinuityV1RecordEncodesTheTakeEventsAsExample08() throws {
            let takeIn = StreamID(validated: "str.take-in")
            let goldens: [GoldenDiscontinuity] = [
                .init("08 seq 2", .overflow(takeIn, frames: 1_024), generation: 1, frame: 480_000, seq: 2,
                      #"{"frame":480000,"frames":1024,"generation":1,"kind":"discontinuity","#
                        + #""sampleClock":"smp.main","seq":2,"stream":"str.take-in","type":"overflow"}"#),
                .init("08 seq 7", .captureStopped(takeIn, reason: .diskFull), generation: 2, frame: 480_000, seq: 7,
                      note: "Writer finalised the partial file.",
                      #"{"frame":480000,"generation":2,"kind":"discontinuity","#
                        + #""note":"Writer finalised the partial file.","reason":"diskFull","sampleClock":"smp.main","#
                        + #""seq":7,"stream":"str.take-in","type":"captureStopped"}"#),
                .init("08 seq 9", .captureStopped(takeIn, reason: .deviceLost), generation: 2, frame: 720_000, seq: 9,
                      #"{"frame":720000,"generation":2,"kind":"discontinuity","reason":"deviceLost","#
                        + #""sampleClock":"smp.main","seq":9,"stream":"str.take-in","type":"captureStopped"}"#)
            ]
            for golden in goldens {
                let record = try DiscontinuityV1Record.make(golden.event, sampleClock: smpMain,
                                                            generation: Generation(golden.generation),
                                                            frame: golden.frame, seq: golden.seq, note: golden.note)
                #expect(try String(data: record.encodedJSON(), encoding: .utf8) == golden.json, "\(golden.label)")
            }
            #expect(goldens.map(\.event.type) == ["overflow", "captureStopped", "captureStopped"])
        }

        /// The take events share `underrun`'s stream and `frames` refusals; a `captureStopped` has no `frames`.
        @Test func discontinuityV1RecordRefusesTheTakeEventsStreamAndOverflowFrames() throws {
            let stream = StreamID(validated: "Str.take-in")
            #expect(discontinuityRefusal(.overflow(stream, frames: 0)) == .invalidStream(stream))
            #expect(discontinuityRefusal(.captureStopped(stream, reason: .deviceLost)) == .invalidStream(stream))
            let limit = DiscontinuityV1Record.maximumFrames
            for frames in [0, -1, Int64.min, limit + 1, Int64.max] {
                #expect(discontinuityRefusal(.overflow(backing, frames: frames)) == .framesOutOfRange(frames))
            }
            #expect(discontinuityRefusal(.overflow(backing, frames: 1)) == nil)
            #expect(discontinuityRefusal(.overflow(backing, frames: limit), note: "") == .invalidNote(bytes: 0))
            #expect(discontinuityRefusal(.captureStopped(backing, reason: .diskFull), note: " ")
                        == .invalidNote(bytes: 1))
        }
    }
}
