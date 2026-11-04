//
//  WorkspaceNavigationTests+Adaptation.swift
//  FluxKlangTests
//
//  Width, mode, compact tabs, the Advanced group and inspector placement of the
//  pure workspace navigation model (#99).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = WorkspaceNavigationTests

extension WorkspaceNavigationTests {
    struct Adaptation {
        static let modes: [WorkspaceMode] = [.edit, .perform]
        static let widths: [WorkspaceWidthClass] = [.regular, .compact]
        static let primarySurfaces: [WorkspaceSurface] = [.wiring, .perform, .spatial]
        static let overflowSurfaces: [WorkspaceSurface] = [.library, .diagnostics, .assistant, .help, .compatibility]
        static let advancedSurfaces: [WorkspaceSurface] = [.diagnostics, .compatibility]

        /// Window A shows `surface` in `mode` with a removed and a live selection and
        /// the inspector requested; window B is customized differently.
        private static func state(
            surface: WorkspaceSurface, mode: WorkspaceMode
        ) throws -> WorkspaceNavigationState {
            let (first, second) = (try Root.node(1), try Root.node(2))
            return try Root.applying([
                .openWindow(Root.windowA), .openWindow(Root.windowB),
                .selectSurface(surface, window: Root.windowA), .setMode(mode, window: Root.windowA),
                .select([first, second], window: Root.windowA),
                .revisionApplied(try Root.revision(4), present: [second]),
                .setInspectorRequested(true, window: Root.windowA),
                .selectSurface(.library, window: Root.windowB), .setWidthClass(.compact, window: Root.windowB),
                .select([second], window: Root.windowB)
            ])
        }

        @Test(arguments: WorkspaceSurface.allCases, Adaptation.modes)
        func regularCompactRoundTripPreservesEverything(surface: WorkspaceSurface, mode: WorkspaceMode) throws {
            let original = try Self.state(surface: surface, mode: mode)
            let windowA = try #require(original.windows[Root.windowA])

            let compact = try Root.applying([.setWidthClass(.compact, window: Root.windowA)], to: original)
            var expected = windowA
            expected.widthClass = .compact
            #expect(compact.windows[Root.windowA] == expected)
            #expect(compact.windows[Root.windowB] == original.windows[Root.windowB])
            #expect(compact.isAdvancedExpanded == original.isAdvancedExpanded)
            #expect(compact.lastAppliedRevision == original.lastAppliedRevision)

            let regular = try Root.applying([.setWidthClass(.regular, window: Root.windowA)], to: compact)
            #expect(regular == original)
        }

        @Test(arguments: WorkspaceSurface.allCases, Adaptation.widths)
        func performAndEditDifferOnlyInTheTwoAffordanceFlags(
            surface: WorkspaceSurface, width: WorkspaceWidthClass
        ) throws {
            let edit = try Root.applying(
                [.setWidthClass(width, window: Root.windowA)], to: Self.state(surface: surface, mode: .edit)
            )
            let perform = try Root.applying([.setMode(.perform, window: Root.windowA)], to: edit)
            var performWindow = try #require(perform.windows[Root.windowA])
            performWindow.mode = .edit
            #expect(performWindow == edit.windows[Root.windowA])

            let editShell = try edit.presentation(for: Root.windowA)
            let performShell = try perform.presentation(for: Root.windowA)
            #expect(editShell.showsLayoutHandles && editShell.showsWiringAffordances)
            #expect(!performShell.showsLayoutHandles && !performShell.showsWiringAffordances)
            #expect(performShell.surface == editShell.surface)
            #expect(performShell.layout == editShell.layout)
            #expect(performShell.inspectorPlacement == editShell.inspectorPlacement)
            #expect(performShell.advancedGroupExpanded == editShell.advancedGroupExpanded)
            #expect(editShell.safetyControlsReachable && performShell.safetyControlsReachable)
        }

        @Test func primaryAndOverflowSurfacesCoverEverySurfaceOnce() {
            let all = Self.primarySurfaces + Self.overflowSurfaces
            #expect(Set(all) == Set(WorkspaceSurface.allCases))
            #expect(all.count == WorkspaceSurface.allCases.count)
        }

        @Test(arguments: Adaptation.overflowSurfaces)
        func compactWidthShowsEveryOverflowSurfaceUnderMore(_ surface: WorkspaceSurface) throws {
            let state = try Root.applying([
                .openWindow(Root.windowA), .selectSurface(surface, window: Root.windowA),
                .setWidthClass(.compact, window: Root.windowA)
            ])
            let shell = try state.presentation(for: Root.windowA)
            #expect(shell.layout == .compact(primaryTabs: [.wiring, .perform, .spatial, .more], activeTab: .more))
            #expect(shell.surface == surface)
            #expect(state.windows[Root.windowA]?.surface == surface)
            #expect(shell.safetyControlsReachable)
        }

        @Test(arguments: zip(Adaptation.primarySurfaces, [WorkspaceCompactTab.wiring, .perform, .spatial]))
        func compactWidthShowsPrimarySurfacesInTheirOwnTab(
            _ surface: WorkspaceSurface, tab: WorkspaceCompactTab
        ) throws {
            let state = try Root.applying([
                .openWindow(Root.windowA), .selectSurface(surface, window: Root.windowA),
                .setWidthClass(.compact, window: Root.windowA)
            ])
            let shell = try state.presentation(for: Root.windowA)
            #expect(shell.layout == .compact(primaryTabs: [.wiring, .perform, .spatial, .more], activeTab: tab))
            #expect(shell.surface == surface)
        }

        @Test func splitSidebarGroupsSurfacesAndShowsAdvancedOnlyWhenExpanded() throws {
            let grouped = Dictionary(grouping: WorkspaceSurface.allCases, by: \.group)
            #expect(grouped == [
                .create: [.wiring, .spatial, .library], .perform: [.perform],
                .help: [.assistant, .help], .advanced: [.diagnostics, .compatibility]
            ])

            let collapsed = try Root.applying([.openWindow(Root.windowA)])
            #expect(try collapsed.presentation(for: Root.windowA).layout == .split(sidebarGroups: [
                .create, .perform, .help
            ]))
            let expanded = try Root.applying([.setAdvancedExpanded(true)], to: collapsed)
            let shell = try expanded.presentation(for: Root.windowA)
            #expect(shell.layout == .split(sidebarGroups: [.create, .perform, .help, .advanced]))
            #expect(shell.advancedGroupExpanded)
            #expect(expanded.windows == collapsed.windows)
        }

        @Test(arguments: Adaptation.advancedSurfaces)
        func advancedAutoExpandsAndRefusesCollapseWhileAnyWindowUsesIt(_ surface: WorkspaceSurface) throws {
            // B opens first, so the refusal must name the smallest ID, not the first opened.
            var state = try Root.applying([
                .openWindow(Root.windowB), .openWindow(Root.windowA),
                .selectSurface(.library, window: Root.windowB)
            ])
            #expect(!state.isAdvancedExpanded)
            try state.apply(.selectSurface(surface, window: Root.windowB))
            #expect(state.isAdvancedExpanded)
            Root.expectRefusal(.advancedInUse(Root.windowB), applying: .setAdvancedExpanded(false), to: state)

            try state.apply(.selectSurface(surface, window: Root.windowA))
            Root.expectRefusal(.advancedInUse(Root.windowA), applying: .setAdvancedExpanded(false), to: state)
            try state.apply(.selectSurface(.help, window: Root.windowA))
            Root.expectRefusal(.advancedInUse(Root.windowB), applying: .setAdvancedExpanded(false), to: state)
            try state.apply(.selectSurface(.perform, window: Root.windowB))
            #expect(state.isAdvancedExpanded)

            try state.apply(.setAdvancedExpanded(false))
            #expect(!state.isAdvancedExpanded)
            #expect(state.windows[Root.windowA]?.surface == .help)
            #expect(state.windows[Root.windowB]?.surface == .perform)
        }

        @Test func closingTheLastAdvancedWindowAllowsCollapse() throws {
            var state = try Root.applying([
                .openWindow(Root.windowA), .openWindow(Root.windowB),
                .selectSurface(.compatibility, window: Root.windowA)
            ])
            try state.apply(.closeWindow(Root.windowA))
            #expect(state.isAdvancedExpanded)
            try state.apply(.setAdvancedExpanded(false))
            #expect(!state.isAdvancedExpanded)
        }

        @Test func collapsingAdvancedWithNoWindowsOpenSucceeds() throws {
            #expect(try Root.applying([.setAdvancedExpanded(false)]) == WorkspaceNavigationState())
            let expanded = try Root.applying([.setAdvancedExpanded(true)])
            #expect(expanded.isAdvancedExpanded)
            #expect(expanded.windows.isEmpty)
            #expect(try Root.applying([.setAdvancedExpanded(false)], to: expanded) == WorkspaceNavigationState())
        }

        @Test(arguments: Adaptation.widths, [false, true])
        func inspectorPlacementFollowsWidthOnlyWhenRequested(width: WorkspaceWidthClass, requested: Bool) throws {
            let state = try Root.applying([
                .openWindow(Root.windowA), .setWidthClass(width, window: Root.windowA),
                .setInspectorRequested(requested, window: Root.windowA)
            ])
            let placement = try state.presentation(for: Root.windowA).inspectorPlacement
            let expected: WorkspaceInspectorPlacement? = switch (width, requested) {
            case (_, false): nil
            case (.regular, true): .trailingPanel
            case (.compact, true): .sheet
            }
            #expect(placement == expected)
            #expect(state.windows[Root.windowA]?.inspectorRequested == requested)
        }
    }
}
