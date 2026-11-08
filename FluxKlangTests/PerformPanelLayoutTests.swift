//
//  PerformPanelLayoutTests.swift
//  FluxKlangTests
//
//  The perform panel layout (#102 PNL1): fixtures, the grid, row-major flow, reflow, the safety strip, kinds and the
//  entry bound. Refusal order, groups and the focus order are in the extension files.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Perform panel layout (#102 PNL1)")
struct PerformPanelLayoutTests {
    static func descriptor(_ id: String, unit: ParameterUnit) throws -> ParameterDescriptor {
        let parameter = try ParameterID(id)
        switch unit {
        case .boolean:
            return try ParameterDescriptor(.init(
                id: parameter, unit: .boolean, lower: 0, upper: 1, defaultValue: 0, ceiling: nil, curve: .stepped,
                ramp: .step, controlClass: .live, verification: .reported
            ))
        case .normalized:
            return try ParameterDescriptor(.init(
                id: parameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0, ceiling: nil, curve: .linear,
                ramp: .step, controlClass: .live, verification: .reported
            ))
        case .decibels, .percent, .pan, .index:
            return try ParameterDescriptor(.init(
                id: parameter, unit: .decibels, lower: -120, upper: 6, defaultValue: -120, ceiling: 0,
                curve: .faderTaper, ramp: .step, controlClass: .live, verification: .reported
            ))
        }
    }

    static func shownValue(_ unit: ParameterUnit) -> ParameterValue {
        switch unit {
        case .boolean: ParameterValue(value: 1, unit: .boolean)
        case .normalized: ParameterValue(value: 0.5, unit: .normalized)
        case .decibels, .percent, .pan, .index: ParameterValue(value: -8, unit: .decibels)
        }
    }

    /// The parameter `par.c<number>` labelled "Cell <number>"; a button is boolean, anything else is decibels.
    static func entry(_ number: Int, kind: PerformControlKind = .fader, group: String? = nil,
                      unit: ParameterUnit? = nil, label: String? = nil) throws -> PerformPanelEntry {
        let shown = unit ?? (kind == .button ? .boolean : .decibels)
        let input = try PerformCellInput(
            descriptor: descriptor("par.c\(number)", unit: shown), value: shownValue(shown),
            labels: PerformCellLabels(cell: label ?? "Cell \(number)", binding: ""), facts: PerformCellFacts(),
            meter: .unavailable(.neverPublished)
        )
        return PerformPanelEntry(kind: kind, group: group, input: input)
    }

    /// `count` ungrouped faders numbered from zero.
    static func entries(_ count: Int) throws -> [PerformPanelEntry] {
        var built: [PerformPanelEntry] = []
        for number in 0..<count { built.append(try entry(number)) }
        return built
    }

    /// The same entry bound to a controller that is waiting for pickup.
    static func waiting(_ entry: PerformPanelEntry) -> PerformPanelEntry {
        var changed = entry
        changed.input.labels.binding = "Fader \(entry.input.labels.cell)"
        changed.input.facts.pickup = .waiting(hardware: nil)
        return changed
    }

    static func build(_ entries: [PerformPanelEntry], regular: Int = 4, compact: Int = 2,
                      width: WorkspaceWidthClass = .regular,
                      previous: PerformPanelLayout? = nil) throws(PerformPanelRefusal) -> PerformPanelLayout {
        let grid = try PerformPanelGrid.make(regularColumns: regular, compactColumns: compact)
        return try PerformPanelLayout.make(entries: entries, grid: grid, width: width, previous: previous)
    }

    static func refusal(_ entries: [PerformPanelEntry]) -> PerformPanelRefusal? {
        do {
            _ = try build(entries)
            return nil
        } catch {
            return error
        }
    }

    static func cells(_ layout: PerformPanelLayout) -> [PerformPanelCell] {
        layout.sections.flatMap { $0.cells }
    }

    static func ids(_ layout: PerformPanelLayout) -> [ParameterID] {
        cells(layout).map { $0.model.parameterID }
    }

    /// The parameter `entry(number)` uses; the fallback is never reached for these digits and would fail the test.
    static func id(_ number: Int) -> ParameterID {
        (try? ParameterID("par.c\(number)")) ?? ParameterID(validated: "par.unreachable")
    }

    static func ids(_ numbers: [Int]) -> [ParameterID] { numbers.map { id($0) } }

    @Test func theGridAcceptsOneToTwelveRegularAndOneToFourCompactColumnsAndRefusesOneBeyondEachEnd() throws {
        let low = try PerformPanelGrid.make(regularColumns: 1, compactColumns: 1)
        let high = try PerformPanelGrid.make(regularColumns: 12, compactColumns: 4)
        #expect(low.regularColumns == 1)
        #expect(low.compactColumns == 1)
        #expect(high.regularColumns == 12)
        #expect(high.compactColumns == 4)
        let cases: [GridCase] = [
            GridCase(regular: 0, compact: 1, refusal: .regularColumnsOutOfRange(0)),
            GridCase(regular: 13, compact: 1, refusal: .regularColumnsOutOfRange(13)),
            GridCase(regular: 1, compact: 0, refusal: .compactColumnsOutOfRange(0)),
            GridCase(regular: 1, compact: 5, refusal: .compactColumnsOutOfRange(5))
        ]
        for item in cases {
            let regular = item.regular
            let compact = item.compact
            let refusal = item.refusal
            #expect(throws: refusal) { try PerformPanelGrid.make(regularColumns: regular, compactColumns: compact) }
        }
    }

    struct FlowCase {
        let columns: Int
        let rows: [Int]
        let positions: [Int]
    }

    struct GridCase {
        let regular: Int
        let compact: Int
        let refusal: PerformPanelRefusal
    }

    @Test func aRegularColumnCountOutOfRangeIsReportedBeforeACompactOneOutOfRange() {
        let expected = PerformPanelRefusal.regularColumnsOutOfRange(13)
        #expect(throws: expected) { try PerformPanelGrid.make(regularColumns: 13, compactColumns: 5) }
        let reversed = PerformPanelRefusal.regularColumnsOutOfRange(0)
        #expect(throws: reversed) { try PerformPanelGrid.make(regularColumns: 0, compactColumns: 0) }
    }

    @Test func cellsFlowRowMajorByTheRegularColumnCountAtOneThreeAndTwelveColumns() throws {
        let panel = try Self.entries(13)
        let oneRows: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        let oneColumns: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let threeRows: [Int] = [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4]
        let threeColumns: [Int] = [0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0]
        let wideRows: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let wideColumns: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0]
        let expected: [FlowCase] = [
            FlowCase(columns: 1, rows: oneRows, positions: oneColumns),
            FlowCase(columns: 3, rows: threeRows, positions: threeColumns),
            FlowCase(columns: 12, rows: wideRows, positions: wideColumns)
        ]
        for item in expected {
            let columns = item.columns
            let layout = try Self.build(panel, regular: columns, compact: 1, width: .regular)
            let placed = Self.cells(layout)
            let actualRows: [Int] = placed.map { $0.row }
            let actualColumns: [Int] = placed.map { $0.column }
            #expect(layout.columns == columns)
            #expect(actualRows == item.rows)
            #expect(actualColumns == item.positions)
        }
    }

    @Test func cellsFlowRowMajorByTheCompactColumnCountAtOneTwoAndFourColumns() throws {
        let panel = try Self.entries(9)
        let oneRows: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8]
        let oneColumns: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0]
        let twoRows: [Int] = [0, 0, 1, 1, 2, 2, 3, 3, 4]
        let twoColumns: [Int] = [0, 1, 0, 1, 0, 1, 0, 1, 0]
        let fourRows: [Int] = [0, 0, 0, 0, 1, 1, 1, 1, 2]
        let fourColumns: [Int] = [0, 1, 2, 3, 0, 1, 2, 3, 0]
        let expected: [FlowCase] = [
            FlowCase(columns: 1, rows: oneRows, positions: oneColumns),
            FlowCase(columns: 2, rows: twoRows, positions: twoColumns),
            FlowCase(columns: 4, rows: fourRows, positions: fourColumns)
        ]
        for item in expected {
            let columns = item.columns
            let layout = try Self.build(panel, regular: 12, compact: columns, width: .compact)
            let placed = Self.cells(layout)
            let actualRows: [Int] = placed.map { $0.row }
            let actualColumns: [Int] = placed.map { $0.column }
            #expect(layout.columns == columns)
            #expect(actualRows == item.rows)
            #expect(actualColumns == item.positions)
        }
    }

    @Test func everyRegularWidthFromOneToTwelveAndEveryCompactWidthFromOneToFourKeepsEveryCell() throws {
        let panel = try Self.entries(25)
        let numbers: [Int] = Array(0..<25)
        let expected: [ParameterID] = Self.ids(numbers)
        for columns in 1...12 {
            let layout = try Self.build(panel, regular: columns, compact: 1, width: .regular)
            let found: [ParameterID] = Self.ids(layout)
            #expect(found == expected)
            #expect(layout.columns == columns)
            for (index, cell) in Self.cells(layout).enumerated() {
                let slot = cell.row * columns + cell.column
                #expect(slot == index)
            }
        }
        for columns in 1...4 {
            let layout = try Self.build(panel, regular: 12, compact: columns, width: .compact)
            let found: [ParameterID] = Self.ids(layout)
            #expect(found == expected)
            #expect(layout.columns == columns)
            for (index, cell) in Self.cells(layout).enumerated() {
                let slot = cell.row * columns + cell.column
                #expect(slot == index)
            }
        }
    }

    @Test func theLayoutUsesTheRegularCountForRegularAndTheCompactCountForCompactWhenTheyDiffer() throws {
        let panel = try Self.entries(6)
        let regular = try Self.build(panel, regular: 5, compact: 2, width: .regular)
        let compact = try Self.build(panel, regular: 5, compact: 2, width: .compact)
        #expect(regular.width == .regular)
        #expect(regular.columns == 5)
        #expect(compact.width == .compact)
        #expect(compact.columns == 2)
        let regularRows: [Int] = Self.cells(regular).map { $0.row }
        let compactRows: [Int] = Self.cells(compact).map { $0.row }
        let expectedRegularRows: [Int] = [0, 0, 0, 0, 0, 1]
        let expectedCompactRows: [Int] = [0, 0, 1, 1, 2, 2]
        #expect(regularRows == expectedRegularRows)
        #expect(compactRows == expectedCompactRows)
    }

    @Test func reflowChangesOnlyTheWidthTheColumnsAndThePlacementOfTheCells() throws {
        var panel: [PerformPanelEntry] = []
        let groups: [String?] = ["Mains", nil, "Vocals", "Mains", nil, "Vocals", "Mains"]
        for (number, group) in groups.enumerated() {
            let base = try Self.entry(number, group: group)
            panel.append(number == 3 ? Self.waiting(base) : base)
        }
        let regular = try Self.build(panel, regular: 3, compact: 2, width: .regular)
        let compact = try Self.build(panel, regular: 3, compact: 2, width: .compact)
        #expect(regular.sections.count == compact.sections.count)
        for (left, right) in zip(regular.sections, compact.sections) {
            #expect(left.group == right.group)
            let leftKinds: [PerformControlKind] = left.cells.map { $0.kind }
            let rightKinds: [PerformControlKind] = right.cells.map { $0.kind }
            let leftModels: [PerformCellModel] = left.cells.map { $0.model }
            let rightModels: [PerformCellModel] = right.cells.map { $0.model }
            #expect(leftKinds == rightKinds)
            #expect(leftModels == rightModels)
        }
        #expect(regular.focusOrder == compact.focusOrder)
        #expect(regular.safety == compact.safety)
        #expect(regular.pickupAnnouncements == compact.pickupAnnouncements)
        let regularPlaces: [Int] = Self.cells(regular).map { $0.row * 10 + $0.column }
        let compactPlaces: [Int] = Self.cells(compact).map { $0.row * 10 + $0.column }
        #expect(regularPlaces != compactPlaces)
        #expect(regular.width != compact.width)
        #expect(regular.columns != compact.columns)
    }

    @Test func anEmptyPanelHasNoSectionsAndStillCarriesPanicAndSafeMuteFirstInTheFocusOrderAtBothWidths() throws {
        for width in [WorkspaceWidthClass.regular, .compact] {
            let layout = try Self.build([], width: width)
            let strip: [CommandOperation] = [.panic, .safeMute]
            let focus: [PerformPanelFocusStop] = [.safety(.panic), .safety(.safeMute)]
            #expect(layout.sections.isEmpty)
            #expect(layout.safety == strip)
            #expect(layout.focusOrder == focus)
            #expect(layout.pickupAnnouncements.isEmpty)
        }
    }

    @Test func theSafetyStripIsWholeAndFirstInAFullPanelOf128EntriesIn16GroupsAtBothWidths() throws {
        var panel: [PerformPanelEntry] = []
        for number in 0..<128 { panel.append(try Self.entry(number, group: "Group \(number % 16)")) }
        for width in [WorkspaceWidthClass.regular, .compact] {
            let layout = try Self.build(panel, width: width)
            let strip: [CommandOperation] = [.panic, .safeMute]
            let leading: [PerformPanelFocusStop] = Array(layout.focusOrder.prefix(2))
            let expectedLeading: [PerformPanelFocusStop] = [.safety(.panic), .safety(.safeMute)]
            #expect(layout.sections.count == 16)
            #expect(layout.safety == strip)
            #expect(leading == expectedLeading)
            #expect(layout.focusOrder.count == 2 + 16 + 128)
            let safetyStops: [PerformPanelFocusStop] = layout.focusOrder.filter {
                if case .safety = $0 { true } else { false }
            }
            #expect(safetyStops.count == 2)
        }
    }

    @Test func thePanelStripAgreesWithTheShellsSafetyRuleAtBothWidthsAndNamesSafetyClassOperations() throws {
        var state = WorkspaceNavigationState()
        let window = WindowID(validated: "win.pnl1")
        try state.apply(.openWindow(window, project: ProjectID(validated: "prj.pnl1")))
        for width in [WorkspaceWidthClass.regular, .compact] {
            try state.apply(.setWidthClass(width, window: window))
            let presentation = try state.presentation(for: window)
            #expect(presentation.safetyControlsReachable)
            let layout = try Self.build(try Self.entries(3), width: width)
            let strip: [CommandOperation] = [.panic, .safeMute]
            #expect(layout.safety == strip)
            for operation in layout.safety {
                #expect(operation.controlClass == .safety)
                #expect(operation.scope == .safety)
            }
        }
    }

    @Test func aButtonNeedsABooleanParameterAndAFaderOrKnobNeedsOneThatIsNotBoolean() throws {
        let good: [(PerformControlKind, ParameterUnit)] = [
            (.fader, .decibels), (.fader, .normalized), (.knob, .decibels), (.knob, .normalized), (.button, .boolean)
        ]
        for (kind, unit) in good {
            let accepted = try Self.build([try Self.entry(0), try Self.entry(1, kind: kind, unit: unit)])
            #expect(Self.cells(accepted).count == 2)
        }
        let bad: [(PerformControlKind, ParameterUnit)] = [
            (.fader, .boolean), (.knob, .boolean), (.button, .decibels), (.button, .normalized)
        ]
        for (kind, unit) in bad {
            let panel = [try Self.entry(0), try Self.entry(1, kind: kind, unit: unit)]
            let expected: PerformPanelRefusal? = .kindUnitMismatch(index: 1, kind: kind, unit: unit)
            #expect(Self.refusal(panel) == expected)
        }
    }

    @Test func aPanelOfZeroOneOr128EntriesIsBuiltAnd129IsRefusedWithItsCount() throws {
        for count in [0, 1, 128] {
            let layout = try Self.build(try Self.entries(count))
            #expect(Self.cells(layout).count == count)
        }
        let expected: PerformPanelRefusal? = .tooManyEntries(count: 129)
        #expect(Self.refusal(try Self.entries(129)) == expected)
    }
}
