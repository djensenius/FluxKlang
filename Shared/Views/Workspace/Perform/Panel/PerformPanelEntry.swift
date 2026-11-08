//
//  PerformPanelEntry.swift
//  FluxKlang
//
//  One control entry of a perform panel and the panel's limits (#102 PNL1). Plain values: no view, no gesture, no
//  command, no hardware.
//

/// The kind of control an entry asks for. XY pads and recalls are not offered by this slice.
enum PerformControlKind: CaseIterable, Equatable, Sendable {
    case fader
    case knob
    case button

    /// A button is the one control for a boolean parameter; a fader or a knob is never one.
    func accepts(_ unit: ParameterUnit) -> Bool {
        switch self {
        case .fader, .knob: unit != .boolean
        case .button: unit == .boolean
        }
    }
}

/// A request for one cell. `PerformPanelLayout.make` validates it; nothing here is checked by being built.
struct PerformPanelEntry: Equatable, Sendable {
    var kind: PerformControlKind
    /// The group label; nil means the entry is ungrouped. A label is identified by its unicode scalars.
    var group: String?
    var input: PerformCellInput
}

enum PerformPanelLimits {
    /// Entries in one panel; more are refused, never dropped.
    static let maximumEntries = 128
    /// utf8 bytes of a group label.
    static let groupLabelBytes = 1...64
    /// Distinct group labels in one panel.
    static let maximumGroups = 16
    static let regularColumns = 1...12
    static let compactColumns = 1...4
}
