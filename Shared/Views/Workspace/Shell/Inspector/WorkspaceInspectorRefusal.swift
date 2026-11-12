//
//  WorkspaceInspectorRefusal.swift
//  FluxKlang
//
//  Why `WorkspaceInspectorSelection.make` refuses its input (#99 INS1). The shell's reducer already keeps a
//  selection duplicate-free and within its cap, so the first two only guard a caller that builds a selection
//  elsewhere. Nothing calls it yet.
//

enum WorkspaceInspectorRefusal: Error, Hashable, Sendable {
    /// More entries than `WorkspaceNavigationState.maxSelection`.
    case selectionLimitExceeded(maximum: Int)
    /// The first entry, in selection order, whose item repeats an earlier one.
    case duplicateSelectionItem(WorkspaceItemRef)
    /// The first live item that exists only in the draft while the caller has no active revision to name.
    case draftItemWithoutActiveRevision(WorkspaceItemRef)
}
