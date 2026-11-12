//
//  ControlContractTests+TimelineV1Refusals.swift
//  FluxKlangTests
//
//  The media contract v1 `timeline` array builder (#84 TRC1): each refusal with its exact payload, the refusal
//  order, the bound, and the rules it leaves to the checker (references and state need the headers).
//

import Foundation
import Testing
@testable import FluxKlang

private typealias Fixtures = ControlContractTests.TimelineV1Fixtures
private typealias Refusal = TimelineV1RecordRefusal

/// A list that `make` refuses, with the refusal it names.
private struct BreakCase {
    let label: String
    let entries: [TimelineV1Entry]
    let expected: Refusal
}

extension ControlContractTests {
    struct TimelineV1Refusals {
        @Test func timelineV1RecordRefusesAnEmptyList() {
            #expect(Fixtures.refusal([]) == .empty)
        }

        /// The only passing list that costs anything: 262,144 cheap dispatch records.
        @Test func timelineV1RecordHoldsTheBoundAndRefusesOneMore() throws {
            let limit = TimelineV1Record.maximumEntries
            #expect(limit == 262_144)
            let entries = try Fixtures.dispatches(limit)
            let record = try TimelineV1Record.make(entries)
            #expect(record.entries.count == limit)
            let over = entries + [try Fixtures.dispatch(limit + 1)]
            #expect(Fixtures.refusal(over) == .tooManyEntries(count: 262_145))
        }

        @Test func timelineV1RecordRefusesTheFirstEntryOutOfPosition() throws {
            // The builders refuse seq 0, so a list that starts at 0 cannot be made.
            let one = try Fixtures.dispatch(1), two = try Fixtures.dispatch(2), three = try Fixtures.dispatch(3)
            let cases = [
                BreakCase(label: "starts at 2", entries: [two],
                          expected: .sequenceBreak(index: 0, expected: 1, found: 2)),
                BreakCase(label: "gap", entries: [one, three],
                          expected: .sequenceBreak(index: 1, expected: 2, found: 3)),
                BreakCase(label: "repeated", entries: [one, one],
                          expected: .sequenceBreak(index: 1, expected: 2, found: 1)),
                BreakCase(label: "swap", entries: [two, one],
                          expected: .sequenceBreak(index: 0, expected: 1, found: 2)),
                BreakCase(label: "first of two breaks", entries: [one, three, two],
                          expected: .sequenceBreak(index: 1, expected: 2, found: 3)),
                BreakCase(label: "late break", entries: [one, two, two, three],
                          expected: .sequenceBreak(index: 2, expected: 3, found: 2))
            ]
            for item in cases {
                #expect(Fixtures.refusal(item.entries) == item.expected, "\(item.label)")
            }
        }

        @Test func timelineV1RecordChecksTheBoundBeforeAnyEntryAndTheSequenceBeforeIDs() throws {
            let one = try Fixtures.dispatch(1)
            let tooMany = Array(repeating: one, count: TimelineV1Record.maximumEntries + 1)
            #expect(Fixtures.refusal(tooMany) == .tooManyEntries(count: 262_145))
            let gapped = [try Fixtures.trigger(1), try Fixtures.trigger(3)]
            #expect(Fixtures.refusal(gapped) == .sequenceBreak(index: 1, expected: 2, found: 3))
        }

        @Test func timelineV1RecordRefusesARepeatedTriggerTakeOrExportID() throws {
            let trigger = [try Fixtures.trigger(1), try Fixtures.trigger(2)]
            #expect(Fixtures.refusal(trigger) == .duplicateTriggerID(TriggerID(validated: "trg.1")))
            let take = [try Fixtures.take(1), try Fixtures.take(2)]
            #expect(Fixtures.refusal(take) == .duplicateTakeID(TakeID(validated: "tk.1")))
            let export = [try Fixtures.export(1), try Fixtures.export(2)]
            #expect(Fixtures.refusal(export) == .duplicateExportID(ExportID(validated: "exp.ump")))
        }

        @Test func timelineV1RecordNamesTheFirstRepeatInTimelineOrder() throws {
            let triggers = [try Fixtures.trigger(1, id: "trg.2"), try Fixtures.trigger(2, id: "trg.1"),
                            try Fixtures.trigger(3, id: "trg.1"), try Fixtures.trigger(4, id: "trg.2")]
            #expect(Fixtures.refusal(triggers) == .duplicateTriggerID(TriggerID(validated: "trg.1")))
            let exportFirst = [try Fixtures.trigger(1), try Fixtures.export(2), try Fixtures.export(3),
                               try Fixtures.trigger(4)]
            #expect(Fixtures.refusal(exportFirst) == .duplicateExportID(ExportID(validated: "exp.ump")))
            let triggerFirst = [try Fixtures.export(1), try Fixtures.trigger(2), try Fixtures.trigger(3),
                                try Fixtures.export(4)]
            #expect(Fixtures.refusal(triggerFirst) == .duplicateTriggerID(TriggerID(validated: "trg.1")))
        }

        @Test func timelineV1RecordKeepsTheThreeIDSpacesApart() throws {
            let same = [try Fixtures.trigger(1), try Fixtures.take(2, id: TakeID(validated: "trg.1")),
                        try Fixtures.export(3, id: ExportID(validated: "trg.1"))]
            #expect(Fixtures.refusal(same) == nil)
            let different = [try Fixtures.trigger(1, id: "trg.1"), try Fixtures.trigger(2, id: "trg.2"),
                             try Fixtures.take(3), try Fixtures.take(4, id: TakeLedgerTestFixture.take2),
                             try Fixtures.export(5), try Fixtures.export(6, id: ExportID(validated: "exp.two"))]
            #expect(Fixtures.refusal(different) == nil)
        }

        /// The checker, with the headers and the trace state, decides these; the list alone cannot.
        @Test func timelineV1RecordAcceptsWhatOnlyTheHeadersAndTheReplayCanJudge() throws {
            let unknownTrigger = try Fixtures.outcome(1, trigger: "trg.9")
            let undeclaredAction = try Fixtures.trigger(2, action: "act.nowhere")
            let unknownAction = try Fixtures.readiness(3, action: "act.ghost")
            let record = try TimelineV1Record.make([unknownTrigger, undeclaredAction, unknownAction])
            #expect(record.entries.map(\.kind) == ["outcome", "trigger", "readiness"])
            #expect(Fixtures.refusal([try Fixtures.outcome(1)]) == nil)
        }
    }
}
