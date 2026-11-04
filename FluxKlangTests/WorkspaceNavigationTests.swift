//
//  WorkspaceNavigationTests.swift
//  FluxKlangTests
//
//  The pure workspace navigation reducer (#99): defaults, windows, limits,
//  selection, revisions, refusals and determinism.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct WorkspaceNavigationTests {
    static let windowA = WindowID(validated: "win.a")
    static let windowB = WindowID(validated: "win.b")
    static let unknownWindow = WindowID(validated: "win.unknown")

    static func node(_ index: Int) throws -> WorkspaceItemRef { .node(try NodeID("nod.\(index)")) }

    static func revision(_ value: Int) throws -> ContractRevision { try ContractRevision(value) }

    static func applying(
        _ actions: [WorkspaceNavigationAction], to start: WorkspaceNavigationState = WorkspaceNavigationState()
    ) throws -> WorkspaceNavigationState {
        var state = start
        for action in actions { try state.apply(action) }
        return state
    }

    /// Window A on Compatibility in Perform at compact width, with a removed and a
    /// live selection and the inspector requested; window B in the default state.
    static func customizedState() throws -> WorkspaceNavigationState {
        let port = WorkspaceItemRef.port(PortID(validated: "prt.a"))
        return try applying([
            .openWindow(windowA),
            .selectSurface(.compatibility, window: windowA),
            .setMode(.perform, window: windowA),
            .setWidthClass(.compact, window: windowA),
            .select([try node(1), port, .edge(EdgeID(validated: "edg.a"))], window: windowA),
            .setInspectorRequested(true, window: windowA),
            .revisionApplied(try revision(5), present: [port]),
            .openWindow(windowB)
        ])
    }

    /// `action` must be refused with `expected` and leave the state Equatable-identical.
    static func expectRefusal(
        _ expected: WorkspaceNavigationError, applying action: WorkspaceNavigationAction,
        to state: WorkspaceNavigationState, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var refused = state
        #expect(throws: expected, sourceLocation: sourceLocation) { try refused.apply(action) }
        #expect(refused == state, sourceLocation: sourceLocation)
    }

    @Test func defaultStateAndNewWindowsAreDefaultAndNeverCloned() throws {
        let empty = WorkspaceNavigationState()
        #expect(empty.windows.isEmpty)
        #expect(!empty.isAdvancedExpanded)
        #expect(empty.lastAppliedRevision == nil)

        let expected = WorkspaceWindowState(
            surface: .wiring, mode: .edit, widthClass: .regular, selection: [], inspectorRequested: false
        )
        let opened = try Self.applying([.openWindow(Self.windowA)])
        #expect(opened.windows == [Self.windowA: expected])

        let customized = try Self.customizedState()
        #expect(customized.windows[Self.windowB] == expected)
        #expect(customized.windows[Self.windowA] != expected)
    }

    @Test func openingAndClosingAnotherWindowLeavesWindowAUnchanged() throws {
        var state = try Self.customizedState()
        let windowA = try #require(state.windows[Self.windowA])
        let other = WindowID(validated: "win.c")
        for action in [
            WorkspaceNavigationAction.closeWindow(Self.windowB), .openWindow(Self.windowB), .openWindow(other),
            .setWidthClass(.compact, window: Self.windowB), .closeWindow(other), .closeWindow(Self.windowB)
        ] {
            let before = state
            try state.apply(action)
            #expect(state.windows[Self.windowA] == windowA)
            #expect(state.isAdvancedExpanded == before.isAdvancedExpanded)
            #expect(state.lastAppliedRevision == before.lastAppliedRevision)
        }
        #expect(state.windows == [Self.windowA: windowA])
    }

    /// Window A customized on a non-advanced surface with a removed and a live item;
    /// window B on Wiring with one live item; Advanced collapsed; revision 3 applied.
    static func isolationState() throws -> WorkspaceNavigationState {
        let port = WorkspaceItemRef.port(PortID(validated: "prt.a"))
        return try applying([
            .openWindow(windowA), .openWindow(windowB),
            .selectSurface(.library, window: windowA), .setMode(.perform, window: windowA),
            .setWidthClass(.compact, window: windowA), .setInspectorRequested(true, window: windowA),
            .select([try node(1), port], window: windowA), .select([try node(9)], window: windowB),
            .revisionApplied(try revision(3), present: [port, try node(9)])
        ])
    }

    /// Each one changes window B of `isolationState()`.
    static let windowBEdits: [WorkspaceNavigationAction] = [
        .setMode(.perform, window: windowB),
        .select([.node(NodeID(validated: "nod.1")), .edge(EdgeID(validated: "edg.b"))], window: windowB),
        .clearSelection(window: windowB),
        .setInspectorRequested(true, window: windowB),
        .selectSurface(.library, window: windowB),
        .selectSurface(.diagnostics, window: windowB),
        .selectSurface(.compatibility, window: windowB)
    ]

    @Test(arguments: WorkspaceNavigationTests.windowBEdits)
    func editingWindowBLeavesWindowAEqual(_ action: WorkspaceNavigationAction) throws {
        let before = try Self.isolationState()
        #expect(!before.isAdvancedExpanded)
        let after = try Self.applying([action], to: before)
        #expect(after.windows[Self.windowA] == before.windows[Self.windowA])
        #expect(after.windows[Self.windowB] != before.windows[Self.windowB])
        #expect(after.windows.keys.sorted() == [Self.windowA, Self.windowB])
        #expect(after.lastAppliedRevision == before.lastAppliedRevision)
        // The only shared field B may change: selecting an advanced surface expands Advanced.
        let expandsAdvanced = if case let .selectSurface(surface, _) = action {
            surface.group == .advanced
        } else {
            false
        }
        #expect(after.isAdvancedExpanded == expandsAdvanced)
    }

    @Test func windowLimitAcceptsSixteenAndRefusesTheSeventeenthAndDuplicates() throws {
        #expect(WorkspaceNavigationState.maxWindows == 16)
        let ids = try (0..<16).map { try WindowID("win.\($0)") }
        var state = try Self.applying(ids.map(WorkspaceNavigationAction.openWindow))
        #expect(state.windows.count == 16)

        let extra = WindowID(validated: "win.extra")
        Self.expectRefusal(.windowLimitExceeded(maximum: 16), applying: .openWindow(extra), to: state)
        Self.expectRefusal(.duplicateWindow(ids[3]), applying: .openWindow(ids[3]), to: state)

        try state.apply(.closeWindow(ids[0]))
        Self.expectRefusal(.duplicateWindow(ids[1]), applying: .openWindow(ids[1]), to: state)
        try state.apply(.openWindow(extra))
        #expect(state.windows.count == 16)
    }

    static let windowScopedActions: [WorkspaceNavigationAction] = [
        .closeWindow(unknownWindow),
        .selectSurface(.perform, window: unknownWindow),
        .setMode(.perform, window: unknownWindow),
        .setWidthClass(.compact, window: unknownWindow),
        .select([.node(NodeID(validated: "nod.x"))], window: unknownWindow),
        .clearSelection(window: unknownWindow),
        .setInspectorRequested(true, window: unknownWindow)
    ]

    @Test(arguments: WorkspaceNavigationTests.windowScopedActions)
    func everyWindowScopedActionRefusesAnUnknownWindow(_ action: WorkspaceNavigationAction) throws {
        Self.expectRefusal(.unknownWindow(Self.unknownWindow), applying: action, to: try Self.customizedState())
    }

    @Test func presentationRefusesAnUnknownWindow() throws {
        let state = try Self.customizedState()
        #expect(throws: WorkspaceNavigationError.unknownWindow(Self.unknownWindow)) {
            try state.presentation(for: Self.unknownWindow)
        }
    }

    @Test func selectionLimitAcceptsTwoHundredFiftySixAndRefusesMore() throws {
        #expect(WorkspaceNavigationState.maxSelection == 256)
        let items = try (0..<257).map(Self.node)
        let full = Array(items.prefix(256))
        let state = try Self.applying([.openWindow(Self.windowA), .select(full, window: Self.windowA)])
        #expect(state.windows[Self.windowA]?.selection == full.map(WorkspaceSelectionEntry.live))
        Self.expectRefusal(
            .selectionLimitExceeded(maximum: 256), applying: .select(items, window: Self.windowA), to: state
        )
    }

    @Test func selectionKeepsOrderIsKeyedByKindAndRefusesDuplicates() throws {
        let sharedRaw = "shared.id"
        let ordered: [WorkspaceItemRef] = [
            .edge(try EdgeID(sharedRaw)), .node(try NodeID(sharedRaw)), .port(try PortID(sharedRaw)), try Self.node(2)
        ]
        let opened = try Self.applying([.openWindow(Self.windowA)])
        let state = try Self.applying([.select(ordered, window: Self.windowA)], to: opened)
        var selected = WorkspaceWindowState()
        selected.selection = ordered.map(WorkspaceSelectionEntry.live)
        #expect(state.windows == [Self.windowA: selected])
        #expect(state.isAdvancedExpanded == opened.isAdvancedExpanded)
        #expect(state.lastAppliedRevision == opened.lastAppliedRevision)

        let duplicate = [try Self.node(1), try Self.node(2), try Self.node(1), try Self.node(2)]
        Self.expectRefusal(
            .duplicateSelectionItem(try Self.node(1)), applying: .select(duplicate, window: Self.windowA), to: state
        )
        let cleared = try Self.applying([.clearSelection(window: Self.windowA)], to: state)
        #expect(cleared.windows[Self.windowA]?.selection == [])
    }

    @Test func selectingNothingEqualsClearingTheSelection() throws {
        let state = try Self.isolationState()
        let cleared = try Self.applying([.clearSelection(window: Self.windowA)], to: state)
        #expect(try Self.applying([.select([], window: Self.windowA)], to: state) == cleared)
        #expect(cleared.windows[Self.windowA]?.selection == [])
    }

    @Test func revisionAppliedMarksAbsentLiveItemsRemovedInOrder() throws {
        let port = WorkspaceItemRef.port(PortID(validated: "prt.p"))
        let edge = WorkspaceItemRef.edge(EdgeID(validated: "edg.e"))
        let (first, second) = (try Self.node(1), try Self.node(2))
        var state = try Self.applying([
            .openWindow(Self.windowA), .openWindow(Self.windowB),
            .select([first, port, edge, second], window: Self.windowA),
            .select([second], window: Self.windowB),
            .revisionApplied(.initial, present: [first, port, edge, second])
        ])
        #expect(state.lastAppliedRevision == .initial)

        let five = try Self.revision(5)
        try state.apply(.revisionApplied(five, present: [port, second]))
        #expect(state.windows[Self.windowA]?.selection == [
            .removed(first, in: five), .live(port), .removed(edge, in: five), .live(second)
        ])
        #expect(state.windows[Self.windowB]?.selection == [.live(second)])
        #expect(state.lastAppliedRevision == five)

        let seven = try Self.revision(7)
        try state.apply(.revisionApplied(seven, present: [first, edge]))
        #expect(state.windows[Self.windowA]?.selection == [
            .removed(first, in: five), .removed(port, in: seven), .removed(edge, in: five), .removed(second, in: seven)
        ])
        #expect(state.windows[Self.windowB]?.selection == [.removed(second, in: seven)])
        #expect(state.windows[Self.windowA]?.selection.map(\.item) == [first, port, edge, second])

        let afterSeven = state
        try state.apply(.revisionApplied(try Self.revision(9), present: []))
        #expect(state.windows == afterSeven.windows)
    }

    @Test func staleAndEqualRevisionsAreRefused() throws {
        let state = try Self.customizedState()
        #expect(state.lastAppliedRevision == (try Self.revision(5)))
        for value in [0, 4, 5] {
            let stale = try Self.revision(value)
            Self.expectRefusal(.staleRevision(stale), applying: .revisionApplied(stale, present: []), to: state)
        }
        let next = try Self.applying([.revisionApplied(try Self.revision(6), present: [])], to: state)
        #expect(next.lastAppliedRevision == (try Self.revision(6)))
    }

    @Test func reselectingARemovedItemMakesItLiveAgain() throws {
        let (item, two) = (try Self.node(1), try Self.revision(2))
        var state = try Self.applying([
            .openWindow(Self.windowA), .select([item], window: Self.windowA), .revisionApplied(two, present: [])
        ])
        #expect(state.windows[Self.windowA]?.selection == [.removed(item, in: two)])
        try state.apply(.select([item], window: Self.windowA))
        #expect(state.windows[Self.windowA]?.selection == [.live(item)])
        #expect(state.lastAppliedRevision == two)
    }

    @Test func aWindowOpenedAfterARevisionStartsEmptyAndKeepsTheRevision() throws {
        let state = try Self.isolationState()
        let three = try Self.revision(3)
        #expect(state.lastAppliedRevision == three)
        let other = WindowID(validated: "win.c")
        let opened = try Self.applying([.openWindow(other)], to: state)
        #expect(opened.windows[other] == WorkspaceWindowState())
        #expect(opened.lastAppliedRevision == three)
        #expect(opened.windows[Self.windowA] == state.windows[Self.windowA])
        #expect(opened.windows[Self.windowB] == state.windows[Self.windowB])
    }

    struct RefusalScenario {
        let state: WorkspaceNavigationState
        let action: WorkspaceNavigationAction
        let expected: WorkspaceNavigationError
    }

    /// One scenario per error case, each against the customized state.
    enum Refusal: CaseIterable, Sendable {
        case unknownWindow, duplicateWindow, windowLimit, selectionLimit, duplicateItem, advancedInUse, staleRevision

        func scenario() throws -> RefusalScenario {
            let state = try WorkspaceNavigationTests.customizedState()
            let windowA = WorkspaceNavigationTests.windowA
            switch self {
            case .unknownWindow:
                let unknown = WorkspaceNavigationTests.unknownWindow
                return RefusalScenario(
                    state: state, action: .setMode(.edit, window: unknown), expected: .unknownWindow(unknown)
                )
            case .duplicateWindow:
                return RefusalScenario(state: state, action: .openWindow(windowA), expected: .duplicateWindow(windowA))
            case .windowLimit:
                let more = try (0..<14).map { WorkspaceNavigationAction.openWindow(try WindowID("win.n\($0)")) }
                return RefusalScenario(
                    state: try WorkspaceNavigationTests.applying(more, to: state),
                    action: .openWindow(WindowID(validated: "win.z")),
                    expected: .windowLimitExceeded(maximum: 16)
                )
            case .selectionLimit:
                let items = try (0..<257).map(WorkspaceNavigationTests.node)
                return RefusalScenario(
                    state: state, action: .select(items, window: windowA),
                    expected: .selectionLimitExceeded(maximum: 256)
                )
            case .duplicateItem:
                let item = try WorkspaceNavigationTests.node(9)
                return RefusalScenario(
                    state: state, action: .select([item, item], window: windowA),
                    expected: .duplicateSelectionItem(item)
                )
            case .advancedInUse:
                return RefusalScenario(
                    state: state, action: .setAdvancedExpanded(false), expected: .advancedInUse(windowA)
                )
            case .staleRevision:
                let stale = try WorkspaceNavigationTests.revision(3)
                return RefusalScenario(
                    state: state, action: .revisionApplied(stale, present: []), expected: .staleRevision(stale)
                )
            }
        }
    }

    @Test(arguments: Refusal.allCases)
    func everyRefusalLeavesTheStateUnchanged(_ refusal: Refusal) throws {
        let scenario = try refusal.scenario()
        Self.expectRefusal(scenario.expected, applying: scenario.action, to: scenario.state)
    }

    @Test func aScriptedSequenceAppliedTwiceGivesEqualStatesAndOutcomes() throws {
        let script: [WorkspaceNavigationAction] = [
            .openWindow(Self.windowB), .openWindow(Self.windowA), .openWindow(Self.windowA),
            .select([try Self.node(3), try Self.node(1)], window: Self.windowA),
            .selectSurface(.diagnostics, window: Self.windowB), .setAdvancedExpanded(false),
            .setWidthClass(.compact, window: Self.windowA), .setMode(.perform, window: Self.windowB),
            .revisionApplied(try Self.revision(2), present: [try Self.node(3)]),
            .revisionApplied(try Self.revision(2), present: []),
            .select([try Self.node(4), try Self.node(4)], window: Self.windowB),
            .setInspectorRequested(true, window: Self.windowA), .closeWindow(Self.unknownWindow),
            .selectSurface(.library, window: Self.windowB), .setAdvancedExpanded(false), .closeWindow(Self.windowB)
        ]
        func run() -> (WorkspaceNavigationState, [WorkspaceNavigationError?]) {
            var state = WorkspaceNavigationState()
            let outcomes = script.map { action -> WorkspaceNavigationError? in
                do throws(WorkspaceNavigationError) { try state.apply(action) } catch { return error }
                return nil
            }
            return (state, outcomes)
        }
        let (first, firstOutcomes) = run()
        let (second, secondOutcomes) = run()
        #expect(first == second)
        #expect(firstOutcomes == secondOutcomes)
        #expect(firstOutcomes.compactMap(\.self) == [
            .duplicateWindow(Self.windowA), .advancedInUse(Self.windowB), .staleRevision(try Self.revision(2)),
            .duplicateSelectionItem(try Self.node(4)), .unknownWindow(Self.unknownWindow)
        ])
        #expect(try first.presentation(for: Self.windowA) == second.presentation(for: Self.windowA))
        #expect(!first.isAdvancedExpanded)
    }
}
