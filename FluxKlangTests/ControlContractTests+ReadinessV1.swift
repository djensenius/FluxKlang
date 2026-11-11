//
//  ControlContractTests+ReadinessV1.swift
//  FluxKlangTests
//
//  The media contract v1 `readinessRecord` builder (#107 RXR1): golden example records byte for byte,
//  the refusal order, every illegal transition, the note rules for `reason` and `note`, and determinism.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Refusal = ReadinessV1RecordRefusal

private let backing = ActionID(validated: "act.backing")
private let stretch = ActionID(validated: "act.stretch")
private let intro = ActionID(validated: "act.intro")

private func readinessRefusal(_ action: ActionID = backing, from: ReadinessState = .ready,
                              to: ReadinessState = .invalidated, seq: Int = 1, reason: String? = "sourceLost",
                              note: String? = nil) -> Refusal? {
    do {
        _ = try ReadinessV1Record.make(action, from: from, to: to, seq: seq, reason: reason, note: note)
        return nil
    } catch {
        return error
    }
}

/// A golden `readinessRecord` from a media contract example (`<example> seq <n>`), keys sorted, compact;
/// the table pins all 13 example readiness records, plus one extra row.
private struct GoldenReadiness {
    let label: String
    let action: ActionID
    let from: ReadinessState
    let to: ReadinessState
    let seq: Int
    let reason: String?
    let note: String?
    let json: String

    init(_ label: String, _ action: ActionID, _ from: ReadinessState, _ to: ReadinessState, _ seq: Int,
         reason: String? = nil, note: String? = nil, _ json: String) {
        (self.label, self.action, self.from, self.to, self.seq) = (label, action, from, to, seq)
        (self.reason, self.note, self.json) = (reason, note, json)
    }
}

private let goldenReadinessRecords: [GoldenReadiness] = [
    .init("03 seq 16", backing, .ready, .invalidated, 16, reason: "locate moved the prefetch head",
          #"{"actionId":"act.backing","from":"ready","kind":"readiness","reason":"locate moved the prefetch head","#
            + #""seq":16,"to":"invalidated"}"#),
    .init("03 seq 18", backing, .invalidated, .preparing, 18,
          #"{"actionId":"act.backing","from":"invalidated","kind":"readiness","seq":18,"to":"preparing"}"#),
    .init("03 seq 19", backing, .preparing, .ready, 19,
          #"{"actionId":"act.backing","from":"preparing","kind":"readiness","seq":19,"to":"ready"}"#),
    .init("04 seq 8", stretch, .unprepared, .preparing, 8,
          #"{"actionId":"act.stretch","from":"unprepared","kind":"readiness","seq":8,"to":"preparing"}"#),
    .init("04 seq 9", stretch, .preparing, .failed, 9, reason: "timeStretchUnavailable",
          #"{"actionId":"act.stretch","from":"preparing","kind":"readiness","reason":"timeStretchUnavailable","#
            + #""seq":9,"to":"failed"}"#),
    .init("05 seq 8", backing, .ready, .invalidated, 8, reason: "sourceLost",
          #"{"actionId":"act.backing","from":"ready","kind":"readiness","reason":"sourceLost","seq":8,"#
            + #""to":"invalidated"}"#),
    .init("05 seq 12", backing, .invalidated, .preparing, 12,
          #"{"actionId":"act.backing","from":"invalidated","kind":"readiness","seq":12,"to":"preparing"}"#),
    .init("05 seq 13", backing, .preparing, .ready, 13,
          #"{"actionId":"act.backing","from":"preparing","kind":"readiness","seq":13,"to":"ready"}"#),
    .init("07 seq 4", intro, .unprepared, .preparing, 4,
          #"{"actionId":"act.intro","from":"unprepared","kind":"readiness","seq":4,"to":"preparing"}"#),
    .init("07 seq 5", intro, .preparing, .ready, 5,
          #"{"actionId":"act.intro","from":"preparing","kind":"readiness","seq":5,"to":"ready"}"#),
    .init("07 seq 8", intro, .ready, .invalidated, 8, reason: "memoryPressure",
          #"{"actionId":"act.intro","from":"ready","kind":"readiness","reason":"memoryPressure","seq":8,"#
            + #""to":"invalidated"}"#),
    .init("07 seq 11", intro, .invalidated, .preparing, 11,
          #"{"actionId":"act.intro","from":"invalidated","kind":"readiness","seq":11,"to":"preparing"}"#),
    .init("07 seq 12", intro, .preparing, .failed, 12, reason: "assetChanged",
          #"{"actionId":"act.intro","from":"preparing","kind":"readiness","reason":"assetChanged","seq":12,"#
            + #""to":"failed"}"#),
    // Not an example: a reason on a transition that does not need one is written as given, next to a note;
    // `/` stays unescaped.
    .init("unprepare", backing, .preparing, .unprepared, 1, reason: "user/cancel", note: "a/b",
          #"{"actionId":"act.backing","from":"preparing","kind":"readiness","note":"a/b","reason":"user/cancel","#
            + #""seq":1,"to":"unprepared"}"#)
]

extension ControlContractTests {
    struct ReadinessV1 {
        @Test func readinessV1RecordEncodesTheGoldenReadinessRecordsExactly() throws {
            #expect(goldenReadinessRecords.count == 14) // 13 example records + 1 extra row
            for golden in goldenReadinessRecords {
                let record = try ReadinessV1Record.make(golden.action, from: golden.from, to: golden.to,
                                                        seq: golden.seq, reason: golden.reason, note: golden.note)
                let json = try #require(String(data: record.encodedJSON(), encoding: .utf8))
                #expect(json == golden.json, "\(golden.label)")
                #expect(record.seq == golden.seq && record.actionID == golden.action, "\(golden.label)")
                #expect(record.from == golden.from && record.to == golden.to, "\(golden.label)")
                #expect(record.reason == golden.reason && record.note == golden.note, "\(golden.label)")
                let again = try ReadinessV1Record.make(golden.action, from: golden.from, to: golden.to,
                                                       seq: golden.seq, reason: golden.reason, note: golden.note)
                #expect(again == record, "\(golden.label)")
                #expect(try again.encodedJSON() == record.encodedJSON(), "\(golden.label)")
            }
        }

        /// `ReadinessState.allowedNext` against the checker's `READINESS` table, copied literally.
        @Test func readinessV1TransitionsFollowTheCheckerTableExhaustively() throws {
            let checker: [ReadinessState: Set<ReadinessState>] = [
                .unprepared: [.preparing], .preparing: [.ready, .failed, .unprepared],
                .ready: [.invalidated, .unprepared], .invalidated: [.preparing, .unprepared],
                .failed: [.preparing, .unprepared]
            ]
            #expect(ReadinessState.allCases.count == 5)
            var legal = 0
            var illegal = 0
            for from in ReadinessState.allCases {
                let allowed = try #require(checker[from])
                #expect(from.allowedNext == allowed, "\(from)")
                for target in ReadinessState.allCases {
                    let refusal = readinessRefusal(from: from, to: target, reason: "why")
                    if allowed.contains(target) {
                        legal += 1
                        #expect(refusal == nil, "\(from) -> \(target)")
                    } else {
                        illegal += 1
                        #expect(refusal == .illegalTransition(from: from, to: target), "\(from) -> \(target)")
                        // Even without a reason the transition is refused first, as is a self-transition.
                        let bare = readinessRefusal(from: from, to: target, reason: nil, note: "")
                        #expect(bare == .illegalTransition(from: from, to: target), "\(from) -> \(target)")
                    }
                }
            }
            #expect(legal == 10 && illegal == 15)
        }

        @Test func readinessV1RecordRefusesInOrderWithoutClampingOrRemapping() throws {
            let upper = ActionID(validated: "Act.backing")
            // Every field bad: each refusal appears once the earlier ones are fixed.
            #expect(readinessRefusal(upper, from: .ready, to: .ready, seq: 0, reason: "", note: "")
                        == .invalidSeq(0))
            #expect(readinessRefusal(upper, from: .ready, to: .ready, reason: "", note: "") == .invalidActionID(upper))
            #expect(readinessRefusal(from: .ready, to: .ready, reason: "", note: "")
                        == .illegalTransition(from: .ready, to: .ready))
            #expect(readinessRefusal(from: .ready, to: .invalidated, reason: nil, note: "")
                        == .missingReason(to: .invalidated))
            #expect(readinessRefusal(from: .ready, to: .invalidated, reason: "", note: "") == .invalidReason(bytes: 0))
            #expect(readinessRefusal(from: .ready, to: .invalidated, reason: "r", note: "") == .invalidNote(bytes: 0))
            #expect(readinessRefusal(seq: -1) == .invalidSeq(-1))
            #expect(readinessRefusal(seq: Int.min) == .invalidSeq(Int.min))
            #expect(readinessRefusal(seq: 1) == nil && readinessRefusal(seq: Int.max) == nil)
            for raw: StaticString in ["act_backing", "act", "act.", "1act.a", "act:1.a", "ACT.BACKING"] {
                let action = ActionID(validated: raw)
                #expect(readinessRefusal(action) == .invalidActionID(action), "\(raw)")
            }
        }

        @Test func readinessV1ReasonIsRequiredOnlyForFailedAndInvalidated() throws {
            #expect(readinessRefusal(from: .preparing, to: .failed, reason: nil) == .missingReason(to: .failed))
            #expect(readinessRefusal(from: .ready, to: .invalidated, reason: nil) == .missingReason(to: .invalidated))
            let optional: [(ReadinessState, ReadinessState)] = [
                (.unprepared, .preparing), (.preparing, .ready), (.preparing, .unprepared), (.ready, .unprepared),
                (.invalidated, .preparing), (.invalidated, .unprepared), (.failed, .preparing), (.failed, .unprepared)
            ]
            for (from, target) in optional {
                #expect(readinessRefusal(from: from, to: target, reason: nil) == nil, "\(from) -> \(target)")
                #expect(readinessRefusal(from: from, to: target, reason: "why") == nil, "\(from) -> \(target)")
                let record = try ReadinessV1Record.make(backing, from: from, to: target, seq: 2)
                let decoded = try JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any]
                let object = try #require(decoded)
                #expect(Set(object.keys) == ["seq", "kind", "actionId", "from", "to"], "\(from) -> \(target)")
            }
        }

        @Test func readinessV1ReasonAndNoteFollowTheTakeNoteRules() throws {
            let limit = ReadinessV1Record.maximumNoteBytes
            #expect(limit == RecordingTakeV1Record.maximumNoteBytes && limit == 256)
            let ascii = String(repeating: "a", count: limit)
            let accented = String(repeating: "é", count: limit / 2)
            let cases: [(String, Int?)] = [
                ("", 0), (" \n\t", 3), ("\u{00A0}", 2), (ascii + "a", limit + 1),
                (String(repeating: "é", count: limit / 2 + 1), limit + 2),
                (ascii, nil), (accented, nil), (" x ", nil), ("sourceLost", nil)
            ]
            for (text, bytes) in cases {
                let reasonRefusal = readinessRefusal(reason: text)
                let noteRefusal = readinessRefusal(note: text)
                if let bytes {
                    #expect(reasonRefusal == .invalidReason(bytes: bytes), "\(bytes)")
                    #expect(noteRefusal == .invalidNote(bytes: bytes), "\(bytes)")
                } else {
                    #expect(reasonRefusal == nil && noteRefusal == nil, "\(text.utf8.count)")
                }
            }
            // Accepted text is written verbatim: not trimmed, truncated or remapped.
            let record = try ReadinessV1Record.make(backing, from: .ready, to: .invalidated, seq: 3, reason: " x ",
                                                    note: accented)
            #expect(record.reason == " x " && record.note == accented)
            let decoded = try JSONSerialization.jsonObject(with: record.encodedJSON()) as? [String: Any]
            let object = try #require(decoded)
            #expect(object["reason"] as? String == " x " && object["note"] as? String == accented)
            #expect(Set(object.keys) == ["seq", "kind", "actionId", "from", "to", "reason", "note"])
            // Text is never normalized: canonically equal reasons give equal records but different bytes.
            let composed = try ReadinessV1Record.make(backing, from: .ready, to: .invalidated, seq: 3,
                                                      reason: "\u{00E9}")
            let decomposed = try ReadinessV1Record.make(backing, from: .ready, to: .invalidated, seq: 3,
                                                        reason: "e\u{0301}")
            #expect(composed == decomposed)
            #expect(try composed.encodedJSON() != decomposed.encodedJSON())
        }
    }
}
