//
//  PerformPanelEditTests.swift
//  FluxKlangTests
//
//  The perform panel editor (#102 PNE1): add, remove and move goldens, the refusal order and the shape of a result.
//  Group and label identity, the limits, pickup and the source scan are in `PerformPanelEditTests+Limits`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Perform panel edit (#102 PNE1)")
struct PerformPanelEditTests {
    typealias Fixture = PerformPanelLayoutTests

    /// A two-column regular and one-column compact context, so positions 0, 2 and 4 start a row at regular width.
    static func context(width: WorkspaceWidthClass = .regular,
                        previous: PerformPanelLayout? = nil) throws -> PerformPanelEditContext {
        let grid = try PerformPanelGrid.make(regularColumns: 2, compactColumns: 1)
        return PerformPanelEditContext(grid: grid, width: width, previous: previous)
    }

    static func cell(_ number: Int, in layout: PerformPanelLayout) throws -> PerformPanelCell {
        let target = Fixture.id(number)
        return try #require(Fixture.cells(layout).first { $0.model.parameterID == target })
    }

    static func order(_ edited: PerformPanelEdited) -> [ParameterID] {
        edited.entries.map { $0.input.descriptor.fields.id }
    }

    /// Four entries whose second one is a button on a decibel parameter, which the layout refuses.
    static func mismatched() throws -> [PerformPanelEntry] {
        var panel = try Fixture.entries(4)
        panel[1] = try Fixture.entry(1, kind: .button, unit: .decibels)
        return panel
    }

    @Test func addingAtTheStartTheMiddleAndTheEndGivesTheHandTypedOrdersAndPositions() throws {
        let panel = try Fixture.entries(4)
        let extra = try Fixture.entry(9)
        let context = try Self.context()
        let atStart = try PerformPanelEditor.adding(extra, at: 0, to: panel, context: context)
        let atMiddle = try PerformPanelEditor.adding(extra, at: 2, to: panel, context: context)
        let atEnd = try PerformPanelEditor.adding(extra, at: 4, to: panel, context: context)
        #expect(Self.order(atStart) == Fixture.ids([9, 0, 1, 2, 3]))
        #expect(Self.order(atMiddle) == Fixture.ids([0, 1, 9, 2, 3]))
        #expect(Self.order(atEnd) == Fixture.ids([0, 1, 2, 3, 9]))
        #expect(Fixture.ids(atStart.layout) == Fixture.ids([9, 0, 1, 2, 3]))
        #expect(Fixture.ids(atMiddle.layout) == Fixture.ids([0, 1, 9, 2, 3]))
        #expect(Fixture.ids(atEnd.layout) == Fixture.ids([0, 1, 2, 3, 9]))
        let first = try Self.cell(9, in: atStart.layout)
        let second = try Self.cell(9, in: atMiddle.layout)
        let third = try Self.cell(9, in: atEnd.layout)
        #expect(first.row == 0)
        #expect(first.column == 0)
        #expect(second.row == 1)
        #expect(second.column == 0)
        #expect(third.row == 2)
        #expect(third.column == 0)
        #expect(atStart.change == .changed)
        #expect(atMiddle.change == .changed)
        #expect(atEnd.change == .changed)
    }

    @Test func addingOutsideZeroThroughTheCountIsRefusedWithTheLargestIndexAndTheEmptyListTakesIndexZero() throws {
        let panel = try Fixture.entries(4)
        let extra = try Fixture.entry(9)
        let context = try Self.context()
        let past = PerformPanelEditRefusal.indexOutOfRange(index: 5, largest: 4)
        let before = PerformPanelEditRefusal.indexOutOfRange(index: -1, largest: 4)
        #expect(throws: past) { try PerformPanelEditor.adding(extra, at: 5, to: panel, context: context) }
        #expect(throws: before) { try PerformPanelEditor.adding(extra, at: -1, to: panel, context: context) }
        let empty = PerformPanelEditRefusal.indexOutOfRange(index: 1, largest: 0)
        #expect(throws: empty) { try PerformPanelEditor.adding(extra, at: 1, to: [], context: context) }
        let alone = try PerformPanelEditor.adding(extra, at: 0, to: [], context: context)
        #expect(Self.order(alone) == Fixture.ids([9]))
        #expect(alone.change == .changed)
    }

    @Test func addingAnExistingParameterIsTheLayoutsDuplicateTargetRefusal() throws {
        let panel = try Fixture.entries(4)
        let again = try Fixture.entry(2, label: "Another")
        let context = try Self.context()
        let expected = PerformPanelEditRefusal.layout(.duplicateTarget(Fixture.id(2)))
        #expect(throws: expected) { try PerformPanelEditor.adding(again, at: 0, to: panel, context: context) }
    }

    @Test func removingAMiddleEntryClosesTheGapAndMovesTheNextCellUpOneColumn() throws {
        let panel = try Fixture.entries(4)
        let context = try Self.context()
        let edited = try PerformPanelEditor.removing(Fixture.id(1), from: panel, context: context)
        #expect(Self.order(edited) == Fixture.ids([0, 2, 3]))
        #expect(Fixture.ids(edited.layout) == Fixture.ids([0, 2, 3]))
        let moved = try Self.cell(2, in: edited.layout)
        let last = try Self.cell(3, in: edited.layout)
        #expect(moved.row == 0)
        #expect(moved.column == 1)
        #expect(last.row == 1)
        #expect(last.column == 0)
        #expect(edited.change == .changed)
    }

    @Test func removingTheOnlyEntryGivesTheEmptyPanelWithTheSafetyStripAndAMissingTargetIsRefused() throws {
        let context = try Self.context()
        let alone = try Fixture.entries(1)
        let edited = try PerformPanelEditor.removing(Fixture.id(0), from: alone, context: context)
        #expect(edited.entries.isEmpty)
        #expect(edited.layout.sections.isEmpty)
        let strip: [CommandOperation] = [.panic, .safeMute]
        #expect(edited.layout.safety == strip)
        #expect(edited.change == .changed)
        let missing = PerformPanelEditRefusal.targetNotFound(Fixture.id(7))
        #expect(throws: missing) { try PerformPanelEditor.removing(Fixture.id(7), from: alone, context: context) }
        #expect(throws: missing) { try PerformPanelEditor.removing(Fixture.id(7), from: [], context: context) }
    }

    @Test func movingToTheEndTheFrontAndOneStepGivesTheFinalPositions() throws {
        let panel = try Fixture.entries(4)
        let context = try Self.context()
        let toEnd = try PerformPanelEditor.moving(Fixture.id(0), to: 3, in: panel, context: context)
        let oneStep = try PerformPanelEditor.moving(Fixture.id(0), to: 1, in: panel, context: context)
        let toFront = try PerformPanelEditor.moving(Fixture.id(3), to: 0, in: panel, context: context)
        let inside = try PerformPanelEditor.moving(Fixture.id(1), to: 2, in: panel, context: context)
        #expect(Self.order(toEnd) == Fixture.ids([1, 2, 3, 0]))
        #expect(Self.order(oneStep) == Fixture.ids([1, 0, 2, 3]))
        #expect(Self.order(toFront) == Fixture.ids([3, 0, 1, 2]))
        #expect(Self.order(inside) == Fixture.ids([0, 2, 1, 3]))
        #expect(Fixture.ids(toEnd.layout) == Fixture.ids([1, 2, 3, 0]))
        #expect(toEnd.change == .changed)
        #expect(oneStep.change == .changed)
        #expect(toFront.change == .changed)
        #expect(inside.change == .changed)
    }

    @Test func movingToTheCurrentIndexIsUnchangedAndABadIndexOrAMissingTargetIsRefused() throws {
        let panel = try Fixture.entries(4)
        let context = try Self.context()
        let same = try PerformPanelEditor.moving(Fixture.id(2), to: 2, in: panel, context: context)
        #expect(same.change == .unchanged)
        #expect(same.entries == panel)
        let past = PerformPanelEditRefusal.indexOutOfRange(index: 4, largest: 3)
        let before = PerformPanelEditRefusal.indexOutOfRange(index: -1, largest: 3)
        #expect(throws: past) { try PerformPanelEditor.moving(Fixture.id(0), to: 4, in: panel, context: context) }
        #expect(throws: before) { try PerformPanelEditor.moving(Fixture.id(0), to: -1, in: panel, context: context) }
        let missing = PerformPanelEditRefusal.targetNotFound(Fixture.id(7))
        #expect(throws: missing) { try PerformPanelEditor.moving(Fixture.id(7), to: 0, in: panel, context: context) }
        #expect(throws: missing) { try PerformPanelEditor.moving(Fixture.id(7), to: 0, in: [], context: context) }
    }

    @Test func theEntryCapIsCheckedBeforeEachOperationsOwnInput() throws {
        let overfull = try Fixture.entries(129)
        let context = try Self.context()
        let extra = try Fixture.entry(500)
        let capped = PerformPanelEditRefusal.layout(.tooManyEntries(count: 129))
        let absent = Fixture.id(900)
        #expect(throws: capped) { try PerformPanelEditor.adding(extra, at: 5_000, to: overfull, context: context) }
        #expect(throws: capped) { try PerformPanelEditor.removing(absent, from: overfull, context: context) }
        #expect(throws: capped) { try PerformPanelEditor.moving(absent, to: 5_000, in: overfull, context: context) }
        #expect(throws: capped) { try PerformPanelEditor.regrouping(absent, to: "G", in: overfull, context: context) }
        #expect(throws: capped) { try PerformPanelEditor.relabeling(absent, to: "L", in: overfull, context: context) }
    }

    @Test func anOperationsOwnInputIsCheckedBeforeTheLayoutOfAListThatAlsoHasAKindMismatch() throws {
        let panel = try Self.mismatched()
        let context = try Self.context()
        let extra = try Fixture.entry(9)
        let absent = Fixture.id(7)
        let missing = PerformPanelEditRefusal.targetNotFound(absent)
        #expect(throws: missing) { try PerformPanelEditor.removing(absent, from: panel, context: context) }
        #expect(throws: missing) { try PerformPanelEditor.moving(absent, to: 0, in: panel, context: context) }
        #expect(throws: missing) { try PerformPanelEditor.regrouping(absent, to: "G", in: panel, context: context) }
        #expect(throws: missing) { try PerformPanelEditor.relabeling(absent, to: "L", in: panel, context: context) }
        let adding = PerformPanelEditRefusal.indexOutOfRange(index: 9, largest: 4)
        let moving = PerformPanelEditRefusal.indexOutOfRange(index: 9, largest: 3)
        #expect(throws: adding) { try PerformPanelEditor.adding(extra, at: 9, to: panel, context: context) }
        #expect(throws: moving) { try PerformPanelEditor.moving(Fixture.id(0), to: 9, in: panel, context: context) }
        let mismatch = PerformPanelEditRefusal.layout(.kindUnitMismatch(index: 0, kind: .button, unit: .decibels))
        #expect(throws: mismatch) { try PerformPanelEditor.removing(Fixture.id(0), from: panel, context: context) }
    }

    @Test func movingChecksTheTargetBeforeTheIndex() throws {
        let panel = try Fixture.entries(4)
        let context = try Self.context()
        let absent = Fixture.id(7)
        let missing = PerformPanelEditRefusal.targetNotFound(absent)
        #expect(throws: missing) { try PerformPanelEditor.moving(absent, to: 99, in: panel, context: context) }
        #expect(throws: missing) { try PerformPanelEditor.moving(absent, to: -1, in: panel, context: context) }
        let badIndex = PerformPanelEditRefusal.indexOutOfRange(index: 99, largest: 3)
        #expect(throws: badIndex) { try PerformPanelEditor.moving(Fixture.id(1), to: 99, in: panel, context: context) }
    }

    @Test func aNoOpEditOfAListTheLayoutRefusesIsTheLayoutRefusalAndNeverUnchanged() throws {
        let panel = try Self.mismatched()
        let context = try Self.context()
        let mismatch = PerformPanelEditRefusal.layout(.kindUnitMismatch(index: 1, kind: .button, unit: .decibels))
        let target = Fixture.id(0)
        #expect(throws: mismatch) {
            try PerformPanelEditor.relabeling(target, to: "Cell 0", in: panel, context: context)
        }
        #expect(throws: mismatch) { try PerformPanelEditor.regrouping(target, to: nil, in: panel, context: context) }
        #expect(throws: mismatch) { try PerformPanelEditor.moving(target, to: 0, in: panel, context: context) }
    }

    @Test func theFiveEditsLeaveEveryOtherEntryEqualToItsInput() throws {
        let panel = try Fixture.grouped(["A", nil, "B", "A"])
        let extra = try Fixture.entry(9, group: "Z")
        let context = try Self.context()
        let added = try PerformPanelEditor.adding(extra, at: 2, to: panel, context: context)
        let removed = try PerformPanelEditor.removing(Fixture.id(1), from: panel, context: context)
        let moved = try PerformPanelEditor.moving(Fixture.id(0), to: 3, in: panel, context: context)
        let regrouped = try PerformPanelEditor.regrouping(Fixture.id(1), to: "B", in: panel, context: context)
        let relabelled = try PerformPanelEditor.relabeling(Fixture.id(1), to: "Zed", in: panel, context: context)
        #expect(added.entries == [panel[0], panel[1], extra, panel[2], panel[3]])
        #expect(removed.entries == [panel[0], panel[2], panel[3]])
        #expect(moved.entries == [panel[1], panel[2], panel[3], panel[0]])
        try #require(regrouped.entries.count == 4)
        try #require(relabelled.entries.count == 4)
        #expect(regrouped.entries[0] == panel[0])
        #expect(regrouped.entries[2] == panel[2])
        #expect(regrouped.entries[3] == panel[3])
        #expect(regrouped.entries[1].group == "B")
        #expect(regrouped.entries[1].input == panel[1].input)
        #expect(regrouped.entries[1].kind == panel[1].kind)
        #expect(relabelled.entries[0] == panel[0])
        #expect(relabelled.entries[2] == panel[2])
        #expect(relabelled.entries[3] == panel[3])
        #expect(relabelled.entries[1].input.labels.cell == "Zed")
        #expect(relabelled.entries[1].group == panel[1].group)
        #expect(relabelled.entries[1].kind == panel[1].kind)
    }

    @Test func eachResultLayoutEqualsAFreshLayoutOfTheResultEntries() throws {
        let panel = try Fixture.grouped(["A", nil, "B", "A"])
        let extra = try Fixture.entry(9)
        let context = try Self.context(width: .compact)
        let results: [PerformPanelEdited] = [
            try PerformPanelEditor.adding(extra, at: 1, to: panel, context: context),
            try PerformPanelEditor.removing(Fixture.id(2), from: panel, context: context),
            try PerformPanelEditor.moving(Fixture.id(0), to: 2, in: panel, context: context),
            try PerformPanelEditor.regrouping(Fixture.id(3), to: nil, in: panel, context: context),
            try PerformPanelEditor.relabeling(Fixture.id(3), to: "Other", in: panel, context: context)
        ]
        for result in results {
            let fresh = try Fixture.build(result.entries, regular: 2, compact: 1, width: .compact, previous: nil)
            #expect(result.layout == fresh)
        }
    }

    @Test func twoIdenticalCallsGiveEqualResults() throws {
        let panel = try Fixture.entries(4)
        let context = try Self.context()
        let first = try PerformPanelEditor.moving(Fixture.id(0), to: 2, in: panel, context: context)
        let second = try PerformPanelEditor.moving(Fixture.id(0), to: 2, in: panel, context: context)
        #expect(first == second)
        let third = try PerformPanelEditor.relabeling(Fixture.id(1), to: "Same", in: panel, context: context)
        let fourth = try PerformPanelEditor.relabeling(Fixture.id(1), to: "Same", in: panel, context: context)
        #expect(third == fourth)
    }

    @Test func aParameterListedTwiceInTheInputIsAddressedAtItsFirstOccurrence() throws {
        let first = try Fixture.entry(1)
        let second = try Fixture.entry(1, label: "Other")
        let panel = [try Fixture.entry(0), first, second, try Fixture.entry(2)]
        let context = try Self.context()
        let removed = try PerformPanelEditor.removing(Fixture.id(1), from: panel, context: context)
        #expect(removed.entries == [panel[0], second, panel[3]])
        let model = try Self.cell(1, in: removed.layout).model
        #expect(model.label == "Other")
        let duplicate = PerformPanelEditRefusal.layout(.duplicateTarget(Fixture.id(1)))
        #expect(throws: duplicate) { try PerformPanelEditor.moving(Fixture.id(1), to: 3, in: panel, context: context) }
    }
}
