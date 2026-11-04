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
    /// Opens a window in the default state.
    case openWindow(WindowID)
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
    /// A newer revision: every window's selected live items absent from `present` become removed in it.
    /// `present` is authoritative. The reducer does not cascade edges, so `present` must already omit
    /// the edges that `GraphDocument.removeNode` dropped with their node. Every listed port also
    /// requires its owning `.node(owner)` in `present`; otherwise the port is marked removed
    /// (`WorkspaceItemRef.isPresent(in:)`). W1 models a single open document, so this revision
    /// sequence is global across windows; a multi-project host must key revision state by `ProjectID`
    /// before shell wiring (a W2 follow-up).
    case revisionApplied(ContractRevision, present: Set<WorkspaceItemRef>)
}

/// Why an action was refused. Every refusal leaves the state unchanged.
enum WorkspaceNavigationError: Error, Hashable, Sendable {
    case unknownWindow(WindowID)
    case duplicateWindow(WindowID)
    case windowLimitExceeded(maximum: Int)
    case selectionLimitExceeded(maximum: Int)
    /// The first item that repeats an earlier one.
    case duplicateSelectionItem(WorkspaceItemRef)
    /// Advanced cannot collapse while a window shows one of its surfaces; this
    /// is the smallest such window ID.
    case advancedInUse(WindowID)
    /// The refused revision, which is not newer than the last applied one.
    case staleRevision(ContractRevision)
}
