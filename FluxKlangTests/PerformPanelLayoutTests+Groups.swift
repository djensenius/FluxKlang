//
//  PerformPanelLayoutTests+Groups.swift
//  FluxKlangTests
//
//  Sections, group identity and the group limits of the perform panel layout (#102 PNL1).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformPanelLayoutTests {
    /// Each section's group as unicode scalar values, nil for the ungrouped section.
    static func scalarGroups(_ layout: PerformPanelLayout) -> [[UInt32]?] {
        layout.sections.map { section in section.group.map { $0.unicodeScalars.map { $0.value } } }
    }

    static func scalars(_ text: String) -> [UInt32]? { text.unicodeScalars.map { $0.value } }

    static func sectionIDs(_ layout: PerformPanelLayout) -> [[ParameterID]] {
        layout.sections.map { section in section.cells.map { $0.model.parameterID } }
    }

    static func grouped(_ groups: [String?]) throws -> [PerformPanelEntry] {
        var built: [PerformPanelEntry] = []
        for (number, group) in groups.enumerated() { built.append(try entry(number, group: group)) }
        return built
    }

    @Test func labelsWithBidiZeroWidthAndNulCharactersAreAcceptedAndDistinctByTheirBytes() throws {
        let marks: [String] = ["\u{202E}", "\u{200B}", "\u{0}", "\u{E9}", "e\u{301}", ""]
        var panel: [PerformPanelEntry] = []
        for (number, mark) in marks.enumerated() {
            panel.append(try Self.entry(number, group: "Mix" + mark, label: "Cell" + mark))
        }
        let layout = try Self.build(panel)
        let groups: [[UInt8]] = layout.sections.map { (section: PerformPanelSection) -> [UInt8] in
            Array((section.group ?? "").utf8)
        }
        let labels: [[UInt8]] = Self.cells(layout).map { (cell: PerformPanelCell) -> [UInt8] in
            Array(cell.model.label.utf8)
        }
        let expectedGroups: [[UInt8]] = marks.map { (mark: String) -> [UInt8] in Array(("Mix" + mark).utf8) }
        let expectedLabels: [[UInt8]] = marks.map { (mark: String) -> [UInt8] in Array(("Cell" + mark).utf8) }
        #expect(groups == expectedGroups)
        #expect(labels == expectedLabels)
        #expect(Set(groups).count == 6)
        #expect(Set(labels).count == 6)
        #expect(layout.sections.count == 6)
        let headers = Self.stopBytes(layout.focusOrder)
        #expect(Set(headers).count == headers.count)
    }

    @Test func aGroupLabelMadeOnlyOfInvisibleCharactersIsAcceptedButAnEmptyOneIsRefused() throws {
        let invisible = try Self.build([try Self.entry(0, group: "\u{200B}\u{0}\u{202E}")])
        let found: [UInt8] = Array((invisible.sections.first?.group ?? "").utf8)
        let expected: [UInt8] = Array("\u{200B}\u{0}\u{202E}".utf8)
        #expect(found == expected)
        let refused: PerformPanelRefusal? = .invalidGroupLabel(index: 0, bytes: 0)
        #expect(Self.refusal([try Self.entry(0, group: "")]) == refused)
    }

    @Test func sectionsFollowTheFirstAppearanceOfEachGroupAndKeepInputOrderInsideEachOne() throws {
        let kinds: [PerformControlKind] = [.fader, .knob, .button, .fader, .knob]
        let groups: [String?] = ["B", "A", "B", "C", "A"]
        var panel: [PerformPanelEntry] = []
        try #require(groups.count == kinds.count)
        for (number, kind) in kinds.enumerated() {
            panel.append(try Self.entry(number, kind: kind, group: groups[number]))
        }
        let layout = try Self.build(panel)
        let expectedGroups: [[UInt32]?] = [Self.scalars("B"), Self.scalars("A"), Self.scalars("C")]
        let expectedIDs: [[ParameterID]] = [Self.ids([0, 2]), Self.ids([1, 4]), Self.ids([3])]
        let expectedKinds: [[PerformControlKind]] = [[.fader, .button], [.knob, .knob], [.fader]]
        let actualKinds: [[PerformControlKind]] = layout.sections.map { section in section.cells.map { $0.kind } }
        #expect(Self.scalarGroups(layout) == expectedGroups)
        #expect(Self.sectionIDs(layout) == expectedIDs)
        #expect(actualKinds == expectedKinds)
    }

    @Test func ungroupedEntriesFormOneSectionPlacedAtTheFirstUngroupedEntry() throws {
        let layout = try Self.build(try Self.grouped(["A", nil, "B", nil, "A", nil]))
        let expectedGroups: [[UInt32]?] = [Self.scalars("A"), nil, Self.scalars("B")]
        let expectedIDs: [[ParameterID]] = [Self.ids([0, 4]), Self.ids([1, 3, 5]), Self.ids([2])]
        #expect(Self.scalarGroups(layout) == expectedGroups)
        #expect(Self.sectionIDs(layout) == expectedIDs)
        let onlyUngrouped = try Self.build(try Self.grouped([nil, nil, nil]))
        #expect(onlyUngrouped.sections.count == 1)
        #expect(onlyUngrouped.sections.first?.group == nil)
        let leading = try Self.build(try Self.grouped([nil, "A", nil]))
        let expectedLeading: [[UInt32]?] = [nil, Self.scalars("A")]
        #expect(Self.scalarGroups(leading) == expectedLeading)
    }

    @Test func groupLabelsWithEqualCharactersButDifferentScalarsAreTwoSections() throws {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        #expect(precomposed == decomposed)
        let layout = try Self.build(try Self.grouped([precomposed, decomposed, precomposed]))
        let expectedGroups: [[UInt32]?] = [Self.scalars(precomposed), Self.scalars(decomposed)]
        let expectedIDs: [[ParameterID]] = [Self.ids([0, 2]), Self.ids([1])]
        #expect(Self.scalarGroups(layout) == expectedGroups)
        #expect(Self.sectionIDs(layout) == expectedIDs)
        let headers: [PerformPanelFocusStop] = layout.focusOrder.filter {
            if case .groupHeader = $0 { true } else { false }
        }
        #expect(headers.count == 2)
    }

    @Test func aGroupLabelOfOneAndSixtyFourBytesIsAcceptedAndEmptyOrSixtyFiveIsRefusedByUtf8Count() throws {
        let accepted: [String] = [
            "a", String(repeating: "a", count: 64), String(repeating: "\u{E9}", count: 32),
            String(repeating: "\u{65E5}", count: 21) + "a", String(repeating: "\u{1F600}", count: 16)
        ]
        for label in accepted {
            #expect(label.utf8.count <= 64)
            let layout = try Self.build([try Self.entry(0, group: label)])
            let expected: [[UInt32]?] = [Self.scalars(label)]
            #expect(Self.scalarGroups(layout) == expected)
        }
        let refused: [(String, Int)] = [
            ("", 0), (String(repeating: "a", count: 65), 65), (String(repeating: "\u{E9}", count: 32) + "a", 65),
            (String(repeating: "\u{65E5}", count: 21) + "ab", 65),
            (String(repeating: "\u{1F600}", count: 16) + "a", 65),
            (String(repeating: "\u{E9}", count: 33), 66)
        ]
        for (label, bytes) in refused {
            let expected: PerformPanelRefusal? = .invalidGroupLabel(index: 0, bytes: bytes)
            #expect(Self.refusal([try Self.entry(0, group: label)]) == expected)
        }
    }

    @Test func sixteenGroupsAreAcceptedEvenWithUngroupedEntriesAndSeventeenAreRefusedWithTheirCount() throws {
        var sixteen: [PerformPanelEntry] = []
        for number in 0..<40 { sixteen.append(try Self.entry(number, group: "G\(number % 16)")) }
        sixteen.append(try Self.entry(40))
        let layout = try Self.build(sixteen)
        #expect(layout.sections.count == 17)
        #expect(Self.cells(layout).count == 41)
        var seventeen: [PerformPanelEntry] = []
        for number in 0..<34 { seventeen.append(try Self.entry(number, group: "G\(number % 17)")) }
        let expected: PerformPanelRefusal? = .tooManyGroups(count: 17)
        #expect(Self.refusal(seventeen) == expected)
        let noGroups = try Self.build(try Self.entries(30))
        #expect(noGroups.sections.count == 1)
    }

    @Test func entriesOfOneGroupKeepInputOrderEvenWhenTheirLabelsAndParametersWouldSortDifferently() throws {
        let numbers = [9, 2, 5]
        let labels = ["Zulu", "Alpha", "Mike"]
        var panel: [PerformPanelEntry] = []
        try #require(labels.count == numbers.count)
        for (position, number) in numbers.enumerated() {
            panel.append(try Self.entry(number, group: "Mix", label: labels[position]))
        }
        let layout = try Self.build(panel)
        let expectedIDs: [[ParameterID]] = [Self.ids([9, 2, 5])]
        #expect(Self.sectionIDs(layout) == expectedIDs)
        let shown: [String] = Self.cells(layout).map { $0.model.label }
        #expect(shown == ["Zulu", "Alpha", "Mike"])
    }

    @Test func placementRestartsAtRowZeroColumnZeroInEverySection() throws {
        let layout = try Self.build(try Self.grouped(["A", "B", "A", "B", "A", "B", "A"]), regular: 2, compact: 1)
        let rows: [[Int]] = layout.sections.map { section in section.cells.map { $0.row } }
        let columns: [[Int]] = layout.sections.map { section in section.cells.map { $0.column } }
        let expectedRows: [[Int]] = [[0, 0, 1, 1], [0, 0, 1]]
        let expectedColumns: [[Int]] = [[0, 1, 0, 1], [0, 1, 0]]
        #expect(rows == expectedRows)
        #expect(columns == expectedColumns)
    }
}
