//
//  PerformPanelEditTests+Limits.swift
//  FluxKlangTests
//
//  Group and label identity, the entry, group and label limits, pickup and a gated scan of the production sources of
//  the perform panel editor (#102 PNE1).
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformPanelEditTests {
    static func groups(_ layout: PerformPanelLayout) -> [String?] { layout.sections.map { $0.group } }

    @Test func regroupingIntoAnExistingGroupMergesTheSectionsAndRegroupingToNilUngroups() throws {
        let panel = try Fixture.grouped(["A", nil, "B"])
        let context = try Self.context()
        let merged = try PerformPanelEditor.regrouping(Fixture.id(1), to: "A", in: panel, context: context)
        #expect(Fixture.sectionIDs(merged.layout) == [Fixture.ids([0, 1]), Fixture.ids([2])])
        #expect(Self.groups(merged.layout) == ["A", "B"])
        #expect(merged.change == .changed)
        let freed = try PerformPanelEditor.regrouping(Fixture.id(0), to: nil, in: panel, context: context)
        #expect(Fixture.sectionIDs(freed.layout) == [Fixture.ids([0, 1]), Fixture.ids([2])])
        #expect(Self.groups(freed.layout) == [nil, "B"])
        try #require(freed.entries.count == 3)
        #expect(freed.entries[0].group == nil)
        #expect(freed.change == .changed)
    }

    @Test func movingTheOnlyEntryOfAGroupPastTheOtherSectionsSwapsTheSectionOrder() throws {
        let panel = try Fixture.grouped(["A", nil, "B"])
        let context = try Self.context()
        let before = try PerformPanelEditor.relabeling(Fixture.id(0), to: "Cell 0", in: panel, context: context)
        #expect(Self.groups(before.layout) == ["A", nil, "B"])
        let moved = try PerformPanelEditor.moving(Fixture.id(0), to: 2, in: panel, context: context)
        #expect(Fixture.sectionIDs(moved.layout) == [Fixture.ids([1]), Fixture.ids([2]), Fixture.ids([0])])
        #expect(Self.groups(moved.layout) == [nil, "B", "A"])
    }

    @Test func regroupingToTheSameGroupOrNilToNilIsUnchangedAndMakesTheLayoutOfTheInput() throws {
        let panel = try Fixture.grouped(["A", nil, "B"])
        let context = try Self.context()
        let same = try PerformPanelEditor.regrouping(Fixture.id(0), to: "A", in: panel, context: context)
        let none = try PerformPanelEditor.regrouping(Fixture.id(1), to: nil, in: panel, context: context)
        let fresh = try Fixture.build(panel, regular: 2, compact: 1)
        #expect(same.change == .unchanged)
        #expect(none.change == .unchanged)
        #expect(same.entries == panel)
        #expect(none.entries == panel)
        #expect(same.layout == fresh)
        #expect(none.layout == fresh)
    }

    @Test func regroupingTreatsCanonicallyEquivalentGroupsAsTwoGroupsByTheirScalars() throws {
        let panel = try Fixture.entries(2)
        let context = try Self.context()
        let composed = try PerformPanelEditor.regrouping(Fixture.id(0), to: "\u{E9}", in: panel, context: context)
        let both = try PerformPanelEditor.regrouping(Fixture.id(1), to: "e\u{301}", in: composed.entries,
                                                     context: context)
        let expected: [[UInt32]?] = [[0xE9], [0x65, 0x301]]
        #expect(Fixture.scalarGroups(both.layout) == expected)
        #expect(both.layout.sections.count == 2)
        let again = try PerformPanelEditor.regrouping(Fixture.id(0), to: "\u{E9}", in: composed.entries,
                                                      context: context)
        #expect(again.change == .unchanged)
        let spelled = try PerformPanelEditor.regrouping(Fixture.id(0), to: "e\u{301}", in: composed.entries,
                                                        context: context)
        #expect(spelled.change == .changed)
        #expect(Fixture.scalarGroups(spelled.layout) == [[0x65, 0x301], nil])
    }

    @Test func regroupingComparesWholeBytesNotPrefixesAndNilDiffersFromTheEmptyGroup() throws {
        let panel = [try Fixture.entry(0, group: "Mix1"), try Fixture.entry(1, group: "AB"), try Fixture.entry(2)]
        let context = try Self.context()
        let shorter = try PerformPanelEditor.regrouping(Fixture.id(0), to: "Mix", in: panel, context: context)
        let sibling = try PerformPanelEditor.regrouping(Fixture.id(1), to: "AC", in: panel, context: context)
        let longer = try PerformPanelEditor.regrouping(Fixture.id(1), to: "ABC", in: panel, context: context)
        #expect(shorter.change == .changed)
        #expect(sibling.change == .changed)
        #expect(longer.change == .changed)
        try #require(shorter.entries.count == 3)
        try #require(longer.entries.count == 3)
        #expect(shorter.entries[0].group == "Mix")
        #expect(longer.entries[1].group == "ABC")
        let empty = PerformPanelEditRefusal.layout(.invalidGroupLabel(index: 2, bytes: 0))
        #expect(throws: empty) { try PerformPanelEditor.regrouping(Fixture.id(2), to: "", in: panel, context: context) }
        let freed = try PerformPanelEditor.regrouping(Fixture.id(1), to: nil, in: panel, context: context)
        #expect(freed.change == .changed)
        try #require(freed.entries.count == 3)
        #expect(freed.entries[1].group == nil)
    }

    @Test func relabelingReplacesTheCellLabelAndKeepsTheBindingLabel() throws {
        let panel = [try Fixture.entry(0), try Fixture.entry(1), Fixture.waiting(try Fixture.entry(2))]
        let context = try Self.context()
        let edited = try PerformPanelEditor.relabeling(Fixture.id(2), to: "Lead", in: panel, context: context)
        try #require(edited.entries.count == 3)
        #expect(edited.entries[2].input.labels.cell == "Lead")
        #expect(edited.entries[2].input.labels.binding == "Fader Cell 2")
        let model = try Self.cell(2, in: edited.layout).model
        #expect(model.label == "Lead")
        #expect(model.bindingLabel == "Fader Cell 2")
        #expect(edited.change == .changed)
    }

    @Test func relabelingToTheOwnLabelIsUnchangedButToAnEquivalentSpellingIsChanged() throws {
        let panel = try Fixture.entries(3)
        let context = try Self.context()
        let own = try PerformPanelEditor.relabeling(Fixture.id(2), to: "Cell 2", in: panel, context: context)
        #expect(own.change == .unchanged)
        #expect(own.entries == panel)
        let composed = [try Fixture.entry(0, label: "\u{E9}"), try Fixture.entry(1)]
        let bound = [try Fixture.entry(0), Fixture.waiting(try Fixture.entry(1))]
        let named = try PerformPanelEditor.relabeling(Fixture.id(1), to: "Fader Cell 1", in: bound, context: context)
        #expect(named.change == .changed)
        let spelled = try PerformPanelEditor.relabeling(Fixture.id(0), to: "e\u{301}", in: composed, context: context)
        #expect(spelled.change == .changed)
        try #require(spelled.entries.count == 2)
        #expect(spelled.entries[0].input.labels.cell.unicodeScalars.map { $0.value } == [0x65, 0x301])
    }

    @Test func relabelingToAnEmptyOrADuplicateLabelSurfacesTheLayoutRefusal() throws {
        let panel = try Fixture.entries(4)
        let context = try Self.context()
        let empty = PerformPanelEditRefusal.layout(.cell(index: 2, refusal: .emptyLabel))
        let duplicate = PerformPanelEditRefusal.layout(.duplicateLabel(index: 2))
        #expect(throws: empty) { try PerformPanelEditor.relabeling(Fixture.id(2), to: "", in: panel, context: context) }
        #expect(throws: duplicate) {
            try PerformPanelEditor.relabeling(Fixture.id(2), to: "Cell 0", in: panel, context: context)
        }
        let absent = Fixture.id(7)
        let missing = PerformPanelEditRefusal.targetNotFound(absent)
        #expect(throws: missing) { try PerformPanelEditor.relabeling(absent, to: "X", in: panel, context: context) }
    }

    @Test func labelsThatDifferOnlyByCanonicalEquivalenceAreBothAcceptedOnTwoCells() throws {
        let panel = try Fixture.entries(2)
        let context = try Self.context()
        let first = try PerformPanelEditor.relabeling(Fixture.id(0), to: "\u{E9}", in: panel, context: context)
        let second = try PerformPanelEditor.relabeling(Fixture.id(1), to: "e\u{301}", in: first.entries,
                                                       context: context)
        let labels = Fixture.cells(second.layout).map { Array($0.model.label.utf8) }
        let expected: [[UInt8]] = [[0xC3, 0xA9], [0x65, 0xCC, 0x81]]
        #expect(labels == expected)
        #expect(second.change == .changed)
    }

    @Test func anEditEndingAt128EntriesIsAcceptedAndOneEndingAt129IsRefused() throws {
        let context = try Self.context()
        let extra = try Fixture.entry(500)
        let nearlyFull = try Fixture.entries(127)
        let full = try PerformPanelEditor.adding(extra, at: 127, to: nearlyFull, context: context)
        #expect(full.entries.count == 128)
        #expect(Fixture.cells(full.layout).count == 128)
        let capped = PerformPanelEditRefusal.layout(.tooManyEntries(count: 129))
        let atCap = try Fixture.entries(128)
        #expect(throws: capped) { try PerformPanelEditor.adding(extra, at: 128, to: atCap, context: context) }
    }

    @Test func anInputListOf128EntriesIsEditedAndOneOf129IsRefusedEvenWhenTheEditWouldFitIt() throws {
        let context = try Self.context()
        let atCap = try Fixture.entries(128)
        let shrunk = try PerformPanelEditor.removing(Fixture.id(5), from: atCap, context: context)
        #expect(shrunk.entries.count == 127)
        let below = try PerformPanelEditor.removing(Fixture.id(5), from: try Fixture.entries(127), context: context)
        #expect(below.entries.count == 126)
        let over = try Fixture.entries(129)
        let capped = PerformPanelEditRefusal.layout(.tooManyEntries(count: 129))
        #expect(throws: capped) { try PerformPanelEditor.removing(Fixture.id(5), from: over, context: context) }
        let extra = try Fixture.entry(500)
        #expect(throws: capped) { try PerformPanelEditor.adding(extra, at: 500, to: over, context: context) }
    }

    @Test func sixteenGroupsAreAcceptedAndTheSeventeenthDistinctGroupIsRefused() throws {
        var names: [String?] = (0..<16).map { "G\($0)" }
        names.append(nil)
        let panel = try Fixture.grouped(names)
        let context = try Self.context()
        let existing = try PerformPanelEditor.regrouping(Fixture.id(16), to: "G3", in: panel, context: context)
        #expect(existing.layout.sections.count == 16)
        var fifteen: [String?] = (0..<15).map { "G\($0)" }
        fifteen.append(nil)
        let below = try PerformPanelEditor.regrouping(Fixture.id(15), to: "G15", in: try Fixture.grouped(fifteen),
                                                      context: context)
        #expect(below.layout.sections.count == 16)
        let seventeenth = PerformPanelEditRefusal.layout(.tooManyGroups(count: 17))
        #expect(throws: seventeenth) {
            try PerformPanelEditor.regrouping(Fixture.id(16), to: "G16", in: panel, context: context)
        }
        let sixteenth = try PerformPanelEditor.regrouping(Fixture.id(16), to: "G15", in: panel, context: context)
        #expect(sixteenth.change == .changed)
    }

    @Test func groupLabelsOfOneAndSixtyFourBytesAreAcceptedAndEmptyAndSixtyFiveAreRefused() throws {
        let panel = try Fixture.entries(2)
        let context = try Self.context()
        let one = try PerformPanelEditor.regrouping(Fixture.id(0), to: "g", in: panel, context: context)
        let full = String(repeating: "g", count: 64)
        let sixtyFour = try PerformPanelEditor.regrouping(Fixture.id(0), to: full, in: panel, context: context)
        try #require(one.entries.count == 2)
        try #require(sixtyFour.entries.count == 2)
        #expect(one.entries[0].group == "g")
        #expect(sixtyFour.entries[0].group == full)
        let empty = PerformPanelEditRefusal.layout(.invalidGroupLabel(index: 0, bytes: 0))
        let long = PerformPanelEditRefusal.layout(.invalidGroupLabel(index: 0, bytes: 65))
        let over = String(repeating: "g", count: 65)
        let target = Fixture.id(0)
        #expect(throws: empty) { try PerformPanelEditor.regrouping(target, to: "", in: panel, context: context) }
        #expect(throws: long) { try PerformPanelEditor.regrouping(target, to: over, in: panel, context: context) }
    }

    @Test func cellLabelsOf128BytesAreAcceptedAnd129AreRefusedCountingBytesNotCharacters() throws {
        let panel = try Fixture.entries(2)
        let context = try Self.context()
        let full = String(repeating: "a", count: 128)
        let wide = String(repeating: "\u{E9}", count: 64)
        let accepted = try PerformPanelEditor.relabeling(Fixture.id(0), to: full, in: panel, context: context)
        let below = String(repeating: "a", count: 127)
        let shorter = try PerformPanelEditor.relabeling(Fixture.id(0), to: below, in: panel, context: context)
        try #require(shorter.entries.count == 2)
        #expect(shorter.entries[0].input.labels.cell.utf8.count == 127)
        let bytes = try PerformPanelEditor.relabeling(Fixture.id(0), to: wide, in: panel, context: context)
        try #require(accepted.entries.count == 2)
        try #require(bytes.entries.count == 2)
        #expect(accepted.entries[0].input.labels.cell.utf8.count == 128)
        #expect(bytes.entries[0].input.labels.cell.utf8.count == 128)
        let over = String(repeating: "a", count: 129)
        let tooWide = String(repeating: "\u{E9}", count: 65)
        let long = PerformPanelEditRefusal.layout(.cell(index: 0, refusal: .labelTooLong(bytes: 129)))
        let wideLong = PerformPanelEditRefusal.layout(.cell(index: 0, refusal: .labelTooLong(bytes: 130)))
        let target = Fixture.id(0)
        #expect(throws: long) { try PerformPanelEditor.relabeling(target, to: over, in: panel, context: context) }
        #expect(throws: wideLong) {
            try PerformPanelEditor.relabeling(target, to: tooWide, in: panel, context: context)
        }
    }

    @Test func aFullPanelOf128EntriesInSixteenGroupsIsEditedByEveryOperationThatFitsIt() throws {
        let names: [String?] = (0..<128).map { "G\($0 % 16)" }
        let panel = try Fixture.grouped(names)
        let context = try Self.context()
        let removed = try PerformPanelEditor.removing(Fixture.id(5), from: panel, context: context)
        let readded = try PerformPanelEditor.adding(panel[5], at: 5, to: removed.entries, context: context)
        let moved = try PerformPanelEditor.moving(Fixture.id(5), to: 100, in: panel, context: context)
        let regrouped = try PerformPanelEditor.regrouping(Fixture.id(5), to: "G1", in: panel, context: context)
        let relabelled = try PerformPanelEditor.relabeling(Fixture.id(5), to: "Fresh", in: panel, context: context)
        #expect(removed.entries.count == 127)
        #expect(readded.entries == panel)
        #expect(moved.entries.count == 128)
        #expect(regrouped.layout.sections.count == 16)
        #expect(relabelled.layout.sections.count == 16)
    }

    /// Three cells; the second one is waiting for pickup. The layout of the list with no previous layout.
    static func waitingPanel() throws -> [PerformPanelEntry] {
        [try Fixture.entry(0), Fixture.waiting(try Fixture.entry(1)), try Fixture.entry(2)]
    }

    @Test func aWaitingCellThatMovesStaysWaitingAndIsNotAnnouncedAgain() throws {
        let panel = try Self.waitingPanel()
        let first = try Fixture.build(panel, regular: 2, compact: 1, previous: nil)
        #expect(first.pickupAnnouncements == Fixture.ids([1]))
        let context = try Self.context(previous: first)
        let moved = try PerformPanelEditor.moving(Fixture.id(1), to: 0, in: panel, context: context)
        #expect(moved.layout.pickupAnnouncements.isEmpty)
        let model = try Self.cell(1, in: moved.layout).model
        #expect(!model.announcesPickup)
        #expect(model.pickup == panel[1].input.facts.pickup)
    }

    @Test func aNoOpMoveStillRunsTheLayoutWithTheCallersPreviousLayoutAndTheContextGrid() throws {
        let panel = try Self.waitingPanel()
        let first = try Fixture.build(panel, regular: 2, compact: 1, previous: nil)
        let context = try Self.context(previous: first)
        let same = try PerformPanelEditor.moving(Fixture.id(1), to: 1, in: panel, context: context)
        #expect(same.change == .unchanged)
        #expect(same.layout.pickupAnnouncements.isEmpty)
        let grid = try PerformPanelGrid.make(regularColumns: 3, compactColumns: 2)
        let wide = PerformPanelEditContext(grid: grid, width: .regular, previous: nil)
        let narrow = PerformPanelEditContext(grid: grid, width: .compact, previous: nil)
        let added = try Fixture.entry(9)
        #expect(try PerformPanelEditor.adding(added, at: 0, to: panel, context: wide).layout.columns == 3)
        #expect(try PerformPanelEditor.adding(added, at: 0, to: panel, context: narrow).layout.columns == 2)
        #expect(try PerformPanelEditor.relabeling(Fixture.id(0), to: "Cell 0", in: panel, context: wide)
            .layout.columns == 3)
    }

    @Test func aWaitingCellThatIsRegroupedOrRelabelledIsNotAnnouncedAgain() throws {
        let panel = try Self.waitingPanel()
        let first = try Fixture.build(panel, regular: 2, compact: 1, previous: nil)
        let context = try Self.context(previous: first)
        let regrouped = try PerformPanelEditor.regrouping(Fixture.id(1), to: "Live", in: panel, context: context)
        let relabelled = try PerformPanelEditor.relabeling(Fixture.id(1), to: "Lead", in: panel, context: context)
        #expect(regrouped.layout.pickupAnnouncements.isEmpty)
        #expect(relabelled.layout.pickupAnnouncements.isEmpty)
        let model = try Self.cell(1, in: relabelled.layout).model
        #expect(model.pickup == panel[1].input.facts.pickup)
    }

    @Test func addingOrRemovingAnotherCellDoesNotAnnounceTheWaitingCellAgain() throws {
        let panel = try Self.waitingPanel()
        let first = try Fixture.build(panel, regular: 2, compact: 1, previous: nil)
        let context = try Self.context(previous: first)
        let removed = try PerformPanelEditor.removing(Fixture.id(0), from: panel, context: context)
        let added = try PerformPanelEditor.adding(try Fixture.entry(9), at: 3, to: panel, context: context)
        #expect(removed.layout.pickupAnnouncements.isEmpty)
        #expect(added.layout.pickupAnnouncements.isEmpty)
    }

    @Test func aWaitingCellRemovedAndAddedBackIsAnnouncedAgain() throws {
        let panel = try Self.waitingPanel()
        let first = try Fixture.build(panel, regular: 2, compact: 1, previous: nil)
        let shown = try Self.context(previous: first)
        let removed = try PerformPanelEditor.removing(Fixture.id(1), from: panel, context: shown)
        #expect(removed.layout.pickupAnnouncements.isEmpty)
        let back = try Self.context(previous: removed.layout)
        let readded = try PerformPanelEditor.adding(panel[1], at: 1, to: removed.entries, context: back)
        #expect(readded.layout.pickupAnnouncements == Fixture.ids([1]))
    }

    private static let sourceNames = ["PerformPanelEdited.swift", "PerformPanelEditRefusal.swift",
                                      "PerformPanelEditor.swift"]

    /// The production files of the editor, read from the checkout or from the package mirror; empty when absent.
    static func editorSources() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Views/Workspace/Perform/Panel/Edit/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = sourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == sourceNames.count { return texts }
        }
        return []
    }

    @Test(.enabled(if: !PerformPanelEditTests.editorSources().isEmpty))
    func theEditorSourcesNameNoFloatingPointClockTaskQueueViewOrDefaultCaseAndAllThreeAreRead() {
        let texts = Self.editorSources()
        #expect(texts.count == 3)
        let banned = ["Double", "Float", "Date(", "Clock", "Task", "import SwiftUI", "DispatchQueue", "default:",
                      "try!", "mutating", "static var", "] + ", "+ [", ".contains(", ".filter(", ".sorted(",
                      "static func ==", "static func <"]
        for text in texts {
            for token in banned { #expect(!text.contains(token)) }
        }
    }
}
