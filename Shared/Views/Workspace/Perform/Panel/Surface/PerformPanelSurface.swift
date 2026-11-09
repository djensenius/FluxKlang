//
//  PerformPanelSurface.swift
//  FluxKlang
//
//  A perform panel surface: an existing panel layout plus a trailing block of XY pad cells and a trailing block of
//  recall cells, one focus order and the visible state of each added cell (#102 PNS1). A pure value: it draws
//  nothing, sends nothing, fires nothing, moves no pad.
//

/// An XY pad cell placed after the layout's sections. Only `make` of the surface builds one.
struct PerformPanelSurfaceXYCell: Equatable, Sendable {
    let id: PerformPanelSurfaceCellID
    let label: String
    let xTarget: ParameterID
    let yTarget: ParameterID
    /// The entry's pad, unchanged.
    let pad: PerformXYPad
    /// The states that hold, in the priority order of `PerformCellEvaluation`.
    let states: [PerformCellState]
    let inputResult: PerformInputResult
    /// True only on the update that moves the pad into waiting for pickup with these targets.
    let announcesPickup: Bool
    let row: Int
    let column: Int

    fileprivate init(entry: PerformPanelSurfaceXYEntry, evaluation: PerformCellEvaluation, announcesPickup: Bool,
                     row: Int, column: Int) {
        id = entry.id
        label = entry.label
        xTarget = entry.xTarget
        yTarget = entry.yTarget
        pad = entry.pad
        states = evaluation.states
        inputResult = evaluation.inputResult
        self.announcesPickup = announcesPickup
        self.row = row
        self.column = column
    }
}

/// A recall cell placed after the XY block. Only `make` of the surface builds one.
struct PerformPanelSurfaceRecallCell: Equatable, Sendable {
    let id: PerformPanelSurfaceCellID
    let label: String
    let target: PerformRecallTarget
    /// The entry's phase, unchanged.
    let phase: PerformRecallPhase
    let display: PerformPanelSurfaceRecallDisplay
    let row: Int
    let column: Int

    fileprivate init(entry: PerformPanelSurfaceRecallEntry, display: PerformPanelSurfaceRecallDisplay, row: Int,
                     column: Int) {
        id = entry.id
        label = entry.label
        target = entry.target
        phase = entry.phase
        self.display = display
        self.row = row
        self.column = column
    }
}

/// A panel layout with XY and recall cells after its sections. Only `make` builds one; storage is `let`.
struct PerformPanelSurface: Equatable, Sendable {
    /// The layout as given, its sections and focus order untouched.
    let layout: PerformPanelLayout
    let xyCells: [PerformPanelSurfaceXYCell]
    let recallCells: [PerformPanelSurfaceRecallCell]
    /// The layout's stops (safety strip first), then each XY cell, then each recall cell.
    let focusOrder: [PerformPanelSurfaceStop]
    /// The ids of the XY cells that announce a pickup, in focus order; the layout's own announcements stay its own.
    let xyAnnouncements: [PerformPanelSurfaceCellID]

    private init(layout: PerformPanelLayout, xyCells: [PerformPanelSurfaceXYCell],
                 recallCells: [PerformPanelSurfaceRecallCell]) {
        self.layout = layout
        self.xyCells = xyCells
        self.recallCells = recallCells
        focusOrder = Self.focusStops(layout: layout, xyCells: xyCells, recallCells: recallCells)
        var announced: [PerformPanelSurfaceCellID] = []
        for cell in xyCells where cell.announcesPickup { announced.append(cell.id) }
        xyAnnouncements = announced
    }

    /// The layout's cells plus the XY and recall cells.
    var cellCount: Int { Self.layoutCellCount(layout) + xyCells.count + recallCells.count }

    /// Builds the surface, or throws the first failing check in the order documented on
    /// `PerformPanelSurfaceRefusal`. Nothing is applied: a pad and a recall phase are stored as given.
    ///
    /// `previous` is required: the surface the host showed before, or nil on first sight. An XY pad announces a pickup
    /// only on the update that moves it into waiting; its previous cell is looked up by id and must have the same two
    /// targets, so a pad that is retargeted counts as first sight.
    static func make(layout: PerformPanelLayout, xy pads: [PerformPanelSurfaceXYEntry],
                     recalls: [PerformPanelSurfaceRecallEntry],
                     previous: PerformPanelSurface?) throws(PerformPanelSurfaceRefusal) -> PerformPanelSurface {
        let total = layoutCellCount(layout) + pads.count + recalls.count
        guard total <= PerformPanelLimits.maximumEntries else { throw .tooManyCells(count: total) }
        try validate(layout: layout, pads: pads, recalls: recalls)
        var earlier: [PerformPanelSurfaceCellID: PerformPanelSurfaceXYCell] = [:]
        for cell in previous?.xyCells ?? [] { earlier[cell.id] = cell }
        let placedPads = xyCells(of: pads, columns: layout.columns, earlier: earlier)
        return PerformPanelSurface(layout: layout, xyCells: placedPads,
                                   recallCells: recallCells(of: recalls, columns: layout.columns))
    }

    private static func xyCells(of entries: [PerformPanelSurfaceXYEntry], columns: Int,
                                earlier: [PerformPanelSurfaceCellID: PerformPanelSurfaceXYCell])
        -> [PerformPanelSurfaceXYCell] {
        var cells: [PerformPanelSurfaceXYCell] = []
        for (index, entry) in entries.enumerated() {
            let evaluation = xyEvaluation(of: entry)
            cells.append(PerformPanelSurfaceXYCell(
                entry: entry, evaluation: evaluation,
                announcesPickup: announcesPickup(entry, evaluation: evaluation, earlier: earlier[entry.id]),
                row: index / columns, column: index % columns
            ))
        }
        return cells
    }

    private static func recallCells(of entries: [PerformPanelSurfaceRecallEntry],
                                    columns: Int) -> [PerformPanelSurfaceRecallCell] {
        var cells: [PerformPanelSurfaceRecallCell] = []
        for (index, entry) in entries.enumerated() {
            cells.append(PerformPanelSurfaceRecallCell(
                entry: entry, display: recallDisplay(of: entry), row: index / columns, column: index % columns
            ))
        }
        return cells
    }
}
