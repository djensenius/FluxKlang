//
//  PerformPanelFocus.swift
//  FluxKlang
//
//  The focus order and the pickup announcements of a perform panel (#102 PNL1).
//

/// One stop of the panel's focus order. The synthesized `==` compares a header label as a `String`, so labels that
/// differ only by canonical equivalence compare equal; the layout itself identifies groups by utf8 bytes.
enum PerformPanelFocusStop: Equatable, Sendable {
    /// Panic or safe mute from the fixed safety strip.
    case safety(CommandOperation)
    /// The label of a labelled section; the ungrouped section has none.
    case groupHeader(String)
    case cell(ParameterID)
}

extension PerformPanelLayout {
    /// Panic then safe mute. Both are safety operations, which no cell can stand for.
    static let safetyStrip: [CommandOperation] = [.panic, .safeMute]

    /// The safety operations, then per section in order its header (labelled sections only) and its cells.
    static func focusOrder(safety: [CommandOperation], sections: [PerformPanelSection]) -> [PerformPanelFocusStop] {
        var stops = safety.map { PerformPanelFocusStop.safety($0) }
        for section in sections {
            if let group = section.group { stops.append(.groupHeader(group)) }
            stops.append(contentsOf: section.cells.map { PerformPanelFocusStop.cell($0.model.parameterID) })
        }
        return stops
    }

    /// The parameter of every cell whose model announces a pickup, in focus order.
    static func announcements(of sections: [PerformPanelSection]) -> [ParameterID] {
        var announced: [ParameterID] = []
        for section in sections {
            for cell in section.cells where cell.model.announcesPickup { announced.append(cell.model.parameterID) }
        }
        return announced
    }
}
