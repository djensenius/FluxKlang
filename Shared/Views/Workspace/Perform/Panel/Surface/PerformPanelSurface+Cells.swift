//
//  PerformPanelSurface+Cells.swift
//  FluxKlang
//
//  The rules that give an added cell its visible state: XY states and pickup announcement, the recall display, the
//  focus order and the layout's cell count (#102 PNS1).
//

extension PerformPanelSurface {
    static func layoutCellCount(_ layout: PerformPanelLayout) -> Int {
        var count = 0
        for section in layout.sections { count += section.cells.count }
        return count
    }

    /// The layout's stops in their own order, then one stop per XY cell, then one per recall cell.
    static func focusStops(layout: PerformPanelLayout, xyCells: [PerformPanelSurfaceXYCell],
                           recallCells: [PerformPanelSurfaceRecallCell]) -> [PerformPanelSurfaceStop] {
        var stops = layout.focusOrder.map { PerformPanelSurfaceStop.panel($0) }
        stops.append(contentsOf: xyCells.map { PerformPanelSurfaceStop.xy($0.id) })
        stops.append(contentsOf: recallCells.map { PerformPanelSurfaceStop.recall($0.id) })
        return stops
    }

    /// The cell vocabulary of the panel: the pad's own pickup becomes the cell's pickup fact. A waiting pad says only
    /// that inputs are held until the pad's capture radius catches; the pad itself decides each input.
    static func xyEvaluation(of entry: PerformPanelSurfaceXYEntry) -> PerformCellEvaluation {
        var facts = PerformCellFacts()
        facts.resyncing = entry.facts.resyncing
        facts.permitted = entry.facts.permitted
        facts.targetExists = entry.facts.targetExists
        switch entry.pad.pickup {
        case .waiting: facts.pickup = .waiting(hardware: nil)
        case .engaged: facts.pickup = .engaged(hardware: nil)
        }
        return PerformCellEvaluation(facts: facts, controlClass: .live, signalUnavailable: false)
    }

    /// True when the pad waits now and the previous cell with this id and these two targets did not.
    static func announcesPickup(_ entry: PerformPanelSurfaceXYEntry, evaluation: PerformCellEvaluation,
                                earlier: PerformPanelSurfaceXYCell?) -> Bool {
        guard evaluation.states.contains(.waitingForPickup) else { return false }
        guard let earlier, earlier.xTarget == entry.xTarget, earlier.yTarget == entry.yTarget else { return true }
        return !earlier.states.contains(.waitingForPickup)
    }

    /// What a press would meet now: the reducer's decision for `.press`, the step and any intent discarded.
    static func recallDisplay(of entry: PerformPanelSurfaceRecallEntry) -> PerformPanelSurfaceRecallDisplay {
        let step = PerformRecallReducer.reduce(entry.phase, .press, target: entry.target, facts: entry.facts)
        switch step.decision {
        case .fire: return .ready
        case .awaitConfirm: return .needsConfirm
        case .refused(let refusal): return refusedDisplay(refusal)
        case .dropped(let drop): return .dropped(drop)
        case .released: return .refused(.notAwaitingConfirm)
        }
    }

    private static func refusedDisplay(_ refusal: PerformRecallRefusal) -> PerformPanelSurfaceRecallDisplay {
        switch refusal {
        case .alreadyAwaitingConfirm: .awaitingConfirm
        case .alreadyFired: .fired
        case .notPermitted, .noTarget, .classNotPerformable, .notAwaitingConfirm, .nothingFired: .refused(refusal)
        }
    }
}
