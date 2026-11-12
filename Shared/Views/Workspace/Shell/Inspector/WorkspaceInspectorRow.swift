//
//  WorkspaceInspectorRow.swift
//  FluxKlang
//
//  One selected item as the inspector's header shows it (#99 INS1). Nothing calls it yet.
//

/// Where a selected item stands. `.removed` carries the revision the shell recorded; `.draftOnly` the active
/// revision the caller named.
enum WorkspaceInspectorItemState: Equatable, Sendable {
    case active
    case draftOnly(activeRevision: ContractRevision)
    case removed(revision: ContractRevision)
}

struct WorkspaceInspectorRow: Equatable, Sendable {
    let item: WorkspaceItemRef
    let kindText: String
    let title: String
    /// Secondary text the user can copy.
    let idText: String
    let state: WorkspaceInspectorItemState
    /// nil for an active item.
    let stateText: String?
    let accessibilityLabel: String

    init(item: WorkspaceItemRef, state: WorkspaceInspectorItemState) {
        let title = WorkspaceInspectorText.title(item)
        let stateText = WorkspaceInspectorText.state(state)
        self.item = item
        self.kindText = WorkspaceInspectorText.kind(item)
        self.title = title
        self.idText = WorkspaceInspectorText.idText(item)
        self.state = state
        self.stateText = stateText
        self.accessibilityLabel = WorkspaceInspectorText.accessibilityLabel(title: title, stateText: stateText)
    }
}
