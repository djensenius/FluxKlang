//
//  PerformPanelEdited.swift
//  FluxKlang
//
//  The inputs and the result of one perform panel edit (#102 PNE1). Plain values: no view, no gesture, no command.
//

/// The inputs the layout needs besides the entries: what `PerformPanelLayout.make` is given.
///
/// `previous` is the layout the host showed before this edit (normally the last `PerformPanelEdited.layout`), or nil
/// on first sight. The editor cannot detect a stale one, and a stale `previous` announces a waiting pickup again.
struct PerformPanelEditContext: Equatable, Sendable {
    let grid: PerformPanelGrid
    let width: WorkspaceWidthClass
    let previous: PerformPanelLayout?
}

/// Whether an edit moved anything. A no-op edit is a result, not a refusal.
enum PerformPanelEditChange: Equatable, Sendable {
    case changed
    case unchanged
}

/// The edited entry list and the layout `PerformPanelLayout.make` built from exactly that list. `PerformPanelEditor`
/// is the only production caller of the memberwise initializer; the type has no invariant of its own because the
/// layout is the proof.
struct PerformPanelEdited: Equatable, Sendable {
    let entries: [PerformPanelEntry]
    let layout: PerformPanelLayout
    let change: PerformPanelEditChange
}
