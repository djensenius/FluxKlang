//
//  PerformPanelSurfaceCells.swift
//  FluxKlang
//
//  The slot, the recall display and the focus stop of a perform panel surface (#102 PNS1).
//

/// Where an entry sits in the lists given to `PerformPanelSurface.make`: its index in its own list.
enum PerformPanelSurfaceSlot: Equatable, Sendable {
    // swiftlint:disable:next identifier_name
    case xy(Int)
    case recall(Int)
}

/// What pressing a recall cell would meet now. The surface never applies the press; the caller applies events.
enum PerformPanelSurfaceRecallDisplay: Equatable, Sendable {
    /// A press would fire.
    case ready
    /// A press would only ask for a confirm (a hazardous recall).
    case needsConfirm
    case awaitingConfirm
    case fired
    case refused(PerformRecallRefusal)
    case dropped(PerformRecallDrop)
}

/// One stop of the surface's focus order: the layout's own stops first, then the added cells.
enum PerformPanelSurfaceStop: Equatable, Sendable {
    case panel(PerformPanelFocusStop)
    // swiftlint:disable:next identifier_name
    case xy(PerformPanelSurfaceCellID)
    case recall(PerformPanelSurfaceCellID)
}
