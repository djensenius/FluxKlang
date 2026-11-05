//
//  WorkspaceNavigationReducer.swift
//  FluxKlang
//
//  The actions and refusals of the deterministic workspace navigation reducer
//  (#99). `WorkspaceNavigationState.apply(_:)` and its staged transition live in
//  WorkspaceNavigationModel.swift so that only that file can commit a change.
//

import Foundation

enum WorkspaceNavigationAction: Hashable, Sendable {
    /// Opens a window in the default state, bound to `project` until it closes. There is no
    /// rebind: moving a window to another project is a close followed by an open.
    case openWindow(WindowID, project: ProjectID)
    case closeWindow(WindowID)
    /// Selecting an advanced surface expands Advanced.
    case selectSurface(WorkspaceSurface, window: WindowID)
    case setMode(WorkspaceMode, window: WindowID)
    case setWidthClass(WorkspaceWidthClass, window: WindowID)
    /// Replaces the window's selection with these live items, in this order.
    case select([WorkspaceItemRef], window: WindowID)
    case clearSelection(window: WindowID)
    case setInspectorRequested(Bool, window: WindowID)
    case setAdvancedExpanded(Bool)
    /// A newer revision of `project`: the selected live items absent from `present` become removed in it,
    /// in that project's windows only. Revisions are monotonic per project while any of its windows is
    /// open; closing its last window discards its revision, so a reopened project starts fresh.
    /// `present` is authoritative. The reducer does not cascade edges, so `present` must already omit
    /// the edges that `GraphDocument.removeNode` dropped with their node. Every listed port also
    /// requires its owning `.node(owner)` in `present`; otherwise the port is marked removed
    /// (`WorkspaceItemRef.isPresent(in:)`).
    case revisionApplied(ContractRevision, project: ProjectID, present: Set<WorkspaceItemRef>)
}

/// Why an action was refused. Every refusal leaves the state unchanged.
enum WorkspaceNavigationError: Error, Hashable, Sendable {
    case unknownWindow(WindowID)
    case duplicateWindow(WindowID)
    case windowLimitExceeded(maximum: Int)
    /// Opening a window for a project that is not open while `maxProjects` projects are.
    case projectLimitExceeded(maximum: Int)
    /// A revision for a project with no open window.
    case unknownProject(ProjectID)
    case selectionLimitExceeded(maximum: Int)
    /// The first item that repeats an earlier one.
    case duplicateSelectionItem(WorkspaceItemRef)
    /// Advanced cannot collapse while a window shows one of its surfaces; this
    /// is the smallest such window ID.
    case advancedInUse(WindowID)
    /// The refused revision, which is not newer than the last one applied to its project.
    case staleRevision(ContractRevision)
}
