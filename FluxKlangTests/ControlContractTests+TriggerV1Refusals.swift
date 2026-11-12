//
//  ControlContractTests+TriggerV1Refusals.swift
//  FluxKlangTests
//
//  The media contract v1 `triggerRecord` builder (#107 TXR1): the field boundaries, every refusal and the
//  order in which a stamp that breaks several rules reports them.
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixtures = ControlContractTests.TriggerV1Fixtures
private typealias Refusal = TriggerV1RecordRefusal

private func key(_ kind: GenerationKind, _ subject: String) -> GenerationKey {
    guard let subject = GenerationSubject(rawValue: subject) else { preconditionFailure("bad subject") }
    return GenerationKey(kind: kind, subject: subject)
}

private func requirement(_ kind: GenerationKind, _ subject: String, _ generation: Int = 1) throws
    -> GenerationRequirement {
    GenerationRequirement(key: key(kind, subject), generation: try Generation(generation))
}

private func stamp(trigger: String = "trg.1", action: String = "act.fx",
                   requires: [GenerationRequirement]? = nil,
                   target: TriggerTarget = .asap) throws -> TriggerStamp {
    Fixtures.stamp(trigger: trigger, action: action,
                   requires: try requires ?? Fixtures.requirements(Fixtures.main), target: target)
}

private func refusal(_ stamp: TriggerStamp, seq: Int = 1, note: String? = nil) -> Refusal? {
    do {
        _ = try TriggerV1Record.make(stamp, seq: seq, note: note)
        return nil
    } catch {
        return error
    }
}

extension ControlContractTests {
    struct TriggerV1Refusals {
        @Test func triggerV1FieldBoundariesAreWrittenExactly() throws {
            #expect(refusal(try stamp(), seq: 1) == nil)
            #expect(refusal(try stamp(), seq: Int.max) == nil)
            let seq = try TriggerV1Record.make(stamp(), seq: Int.max)
            #expect(try Fixtures.json(seq).contains(#""seq":9223372036854775807"#))
            for (ticks, text) in [(0, "0"), (UInt64(Int64.max), "9223372036854775807"),
                                  (UInt64.max, "18446744073709551615")] as [(UInt64, String)] {
                let record = try TriggerV1Record.make(
                    Fixtures.stamp(ticks: ticks, requires: Fixtures.requirements(Fixtures.main)), seq: 1)
                #expect(try Fixtures.json(record).contains(#""originHostTicks":\#(text),"#), "\(ticks)")
            }
            for horizon in [Int64.min, Int64.max] {
                let record = try TriggerV1Record.make(
                    Fixtures.stamp(horizon: horizon, requires: Fixtures.requirements(Fixtures.main)), seq: 1)
                #expect(try Fixtures.json(record).contains(#""horizonFrame":\#(horizon),"#), "\(horizon)")
            }
            let top = Generation.maximumValue
            let generations = [try requirement(.sampleClock, "smp.main", 1), try requirement(.context, "ctx.main", top)]
            let record = try TriggerV1Record.make(stamp(requires: generations), seq: 1)
            let expected = #""requires":{"context/ctx.main":\#(top),"sampleClock/smp.main":1}"#
            #expect(try Fixtures.json(record).contains(expected))
            let targets: [(TriggerTarget, String)] = [
                (.grid(ticks: 1), #""gridTicks":1,"#),
                (.grid(ticks: Int64.max), #""gridTicks":9223372036854775807,"#),
                (.musical(atTicks: 0), #""atTicks":0,"#),
                (.musical(atTicks: Int64.max), #""atTicks":9223372036854775807,"#),
                (.sample(atFrame: Int64.min), #""atFrame":-9223372036854775808,"#),
                (.sample(atFrame: Int64.max), #""atFrame":9223372036854775807,"#)
            ]
            for (target, text) in targets {
                #expect(try Fixtures.json(TriggerV1Record.make(stamp(target: target), seq: 1)).contains(text),
                        "\(target)")
            }
        }

        @Test func triggerV1RequirementCountIsOneToEight() throws {
            let subjects = (1...9).map { "src.s\($0)" }
            let all = try subjects.map { try requirement(.source, $0) }
            #expect(refusal(try stamp(requires: [])) == .noRequirements)
            for count in 1...8 {
                #expect(refusal(try stamp(requires: Array(all.prefix(count)))) == nil, "\(count)")
            }
            #expect(refusal(try stamp(requires: all)) == .tooManyRequirements(9))
            let record = try TriggerV1Record.make(stamp(requires: Array(all.prefix(8))), seq: 1)
            #expect(record.requires.count == 8)
        }

        @Test func triggerV1RefusesInvalidSeqAndIDs() throws {
            #expect(refusal(try stamp(), seq: 0) == .invalidSeq(0))
            #expect(refusal(try stamp(), seq: Int.min) == .invalidSeq(Int.min))
            let bad = ["Trg.1", "trg_1", "trg:1", "trg", "trg.", "1trg.a"]
            for raw in bad {
                let trigger = try #require(TriggerID(rawValue: raw), "\(raw)")
                #expect(refusal(try stamp(trigger: raw)) == .invalidTriggerID(trigger), "\(raw)")
                let action = try #require(ActionID(rawValue: raw), "\(raw)")
                #expect(refusal(try stamp(action: raw)) == .invalidActionID(action), "\(raw)")
            }
            #expect(refusal(try stamp(trigger: "trg.1.a-b")) == nil)
            #expect(refusal(try stamp(action: "a-b.c.d")) == nil)
        }

        @Test func triggerV1RefusesRequirementsInTheStampsOrder() throws {
            let map = try requirement(.musicalMap, "mus.main")
            #expect(refusal(try stamp(requires: [map])) == .musicalMapRequirement(map.key))
            for subject in ["Ctx.main", "ctx_main", "ctx:main", "ctx", "ctx."] {
                let bad = try requirement(.context, subject)
                #expect(refusal(try stamp(requires: [bad])) == .invalidRequirementSubject(bad.key), "\(subject)")
            }
            let first = try requirement(.sampleClock, "smp.main")
            #expect(refusal(try stamp(requires: [first, first])) == .duplicateRequirement(first.key))
            let other = try requirement(.sampleClock, "smp.main", 2)
            #expect(refusal(try stamp(requires: [first, other])) == .duplicateRequirement(first.key))
            // The same subject under another kind is a different key.
            #expect(refusal(try stamp(requires: [first, requirement(.context, "smp.main")])) == nil)
            let invalid = try requirement(.context, "Ctx.main")
            // Per requirement a map kind comes before the subject; the duplicate check's place is unobservable (a
            // repeated key already passed both).
            let invalidMap = try requirement(.musicalMap, "Mus.main")
            #expect(refusal(try stamp(requires: [invalidMap])) == .musicalMapRequirement(invalidMap.key))
            // Across requirements the stamp's order decides: a duplicate before an invalid subject, and back.
            #expect(refusal(try stamp(requires: [first, first, invalid])) == .duplicateRequirement(first.key))
            #expect(refusal(try stamp(requires: [first, invalid, first])) == .invalidRequirementSubject(invalid.key))
            #expect(refusal(try stamp(requires: [invalid, first, first])) == .invalidRequirementSubject(invalid.key))
            #expect(refusal(try stamp(requires: [first, map, invalid])) == .musicalMapRequirement(map.key))
            #expect(refusal(try stamp(requires: [invalid, map])) == .invalidRequirementSubject(invalid.key))
        }

        @Test func triggerV1RefusesTargetsOutOfRange() throws {
            #expect(refusal(try stamp(target: .grid(ticks: 0))) == .invalidGrid(0))
            #expect(refusal(try stamp(target: .grid(ticks: Int64.min))) == .invalidGrid(Int64.min))
            #expect(refusal(try stamp(target: .grid(ticks: -1))) == .invalidGrid(-1))
            #expect(refusal(try stamp(target: .musical(atTicks: -1))) == .negativeMusicalTicks(-1))
            #expect(refusal(try stamp(target: .musical(atTicks: Int64.min))) == .negativeMusicalTicks(Int64.min))
            // `quantize` is only compared, never validated: an invalid one changes nothing but the omission.
            let record = try TriggerV1Record.make(stamp(target: .asap), seq: 1, quantize: .grid(ticks: -5))
            #expect(record.target == .asap)
        }

        @Test func triggerV1NoteFollowsTheNoteRules() throws {
            let limit = TriggerV1Record.maximumNoteBytes
            #expect(limit == ReadinessV1Record.maximumNoteBytes && limit == 256)
            let ascii = String(repeating: "a", count: limit)
            let cases: [(String, Int?)] = [
                ("", 0), (" \n\t", 3), ("\u{00A0}", 2), (ascii + "a", limit + 1),
                (String(repeating: "é", count: limit / 2 + 1), limit + 2),
                (ascii, nil), (String(repeating: "é", count: limit / 2), nil), (" x ", nil)
            ]
            for (text, bytes) in cases {
                #expect(refusal(try stamp(), note: text) == bytes.map { .invalidNote(bytes: $0) }, "\(text.utf8.count)")
            }
            let record = try TriggerV1Record.make(stamp(), seq: 1, note: " x/y ")
            #expect(record.note == " x/y ")
            #expect(try Fixtures.json(record).contains(#""note":" x/y ""#))
        }

        @Test func triggerV1RefusesInTheDocumentedOrder() throws {
            let upper = try requirement(.context, "Ctx.main")
            let map = try requirement(.musicalMap, "mus.main")
            let ids = try stamp(trigger: "Trg.1", action: "Act.fx", requires: [], target: .grid(ticks: 0))
            #expect(refusal(ids, seq: 0, note: "") == .invalidSeq(0))
            #expect(refusal(ids, note: "") == .invalidTriggerID(ids.id))
            let action = try stamp(action: "Act.fx", requires: [], target: .grid(ticks: 0))
            #expect(refusal(action, note: "") == .invalidActionID(action.action))
            let empty = try stamp(requires: [], target: .grid(ticks: 0))
            #expect(refusal(empty, note: "") == .noRequirements)
            let many = try stamp(requires: (1...9).map { try requirement(.source, "src.s\($0)") } + [map],
                                 target: .grid(ticks: 0))
            #expect(refusal(many, note: "") == .tooManyRequirements(10))
            let bad = try stamp(requires: [upper, map], target: .grid(ticks: 0))
            #expect(refusal(bad, note: "") == .invalidRequirementSubject(upper.key))
            let grid = try stamp(target: .grid(ticks: 0))
            #expect(refusal(grid, note: "") == .invalidGrid(0))
            let musical = try stamp(target: .musical(atTicks: -1))
            #expect(refusal(musical, note: "") == .negativeMusicalTicks(-1))
            #expect(refusal(try stamp(), note: "") == .invalidNote(bytes: 0))
        }
    }
}
