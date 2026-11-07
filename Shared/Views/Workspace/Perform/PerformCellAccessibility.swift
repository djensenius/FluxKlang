//
//  PerformCellAccessibility.swift
//  FluxKlang
//
//  The single accessibility element of a perform cell (#102 P1): label, value with unit, hint, custom actions in a
//  fixed order, the texts of the states that hold, and the one-time pickup announcement.
//

/// Custom actions of the cell element. The raw value is the text VoiceOver reads. `showBinding` is offered whenever a
/// binding exists. The other three change the control, so they are offered only when the cell takes input, and
/// `learnControl` also needs edit mode and a control that is not hazardous.
enum PerformCellAction: String, Equatable, Sendable {
    case showBinding = "Show binding"
    case setValue = "Set value..."
    case resetToDefault = "Reset to default"
    case learnControl = "Learn control..."
}

/// Exactly one element per cell. Built only by `PerformCellModel.accessibility`.
struct PerformCellAccessibility: Equatable, Sendable {
    let label: String
    /// The control value with its spoken unit, for example "-8 decibels"; never the signal.
    let value: String
    /// Range, ceiling and "Requires authorization", joined by ". ".
    let hint: String
    /// Fixed order: show binding (a binding exists, any state), then, only when the cell takes input, set value and
    /// reset to default, then learn (edit mode, takes input, not hazardous). Fails closed: a cell whose input result
    /// is `droppedStaleIntent`, `rejectedPermission` or `disabled` offers no mutating action.
    let actions: [PerformCellAction]
    /// The cell-shows text of each holding state, in the priority order; engaged and hazardous add none.
    let statuses: [String]
    /// Non-nil only on the update that moves the cell into waiting for pickup.
    let announcement: String?

    fileprivate init(label: String, value: String, hint: String, actions: [PerformCellAction],
                     statuses: [String], announcement: String?) {
        self.label = label
        self.value = value
        self.hint = hint
        self.actions = actions
        self.statuses = statuses
        self.announcement = announcement
    }
}

extension PerformCellModel {
    /// False when an edit would be dropped, rejected or disabled: the cell then offers no mutating action.
    private var takesInput: Bool {
        switch inputResult {
        case .droppedStaleIntent, .rejectedPermission, .disabled: false
        case .accepted, .storedNotRendered, .noDeviceInput, .needsAuthorization, .heldForPickup: true
        }
    }

    var accessibility: PerformCellAccessibility {
        let fields = descriptor.fields
        var hintParts = ["Range \(Self.spoken(fields.lower, fields.unit, unitWord: false)) to "
            + Self.spoken(fields.upper, fields.unit, unitWord: true)]
        if let ceiling = fields.ceiling {
            hintParts.append("Ceiling " + Self.spoken(ceiling, fields.unit, unitWord: true))
        }
        if fields.controlClass == .hazardous { hintParts.append("Requires authorization") }
        var actions: [PerformCellAction] = []
        if hasBinding { actions.append(.showBinding) }
        if takesInput {
            actions.append(contentsOf: [.setValue, .resetToDefault])
            if editMode && fields.controlClass != .hazardous { actions.append(.learnControl) }
        }
        return PerformCellAccessibility(
            label: label,
            value: Self.spoken(value.value, value.unit, unitWord: true),
            hint: hintParts.joined(separator: ". "),
            actions: actions,
            statuses: states.compactMap { statusText(of: $0) },
            announcement: announcesPickup ? "\(bindingLabel) waiting for pickup" : nil
        )
    }

    /// "-8 decibels", "30 percent", "0.5", "on"; a boolean says "off" only for exactly 0 and "on" only for exactly 1.
    /// `unitWord` false leaves the unit off the lower end of a range.
    private static func spoken(_ number: Double, _ unit: ParameterUnit, unitWord: Bool) -> String {
        if unit == .boolean, number == 0 || number == 1 { return number == 0 ? "off" : "on" }
        let text = PerformNumberText.text(number)
        guard unitWord else { return text }
        switch unit {
        case .decibels: return text + " decibels"
        case .percent: return text + " percent"
        case .normalized, .pan, .index, .boolean: return text
        }
    }

    private func statusText(of state: PerformCellState) -> String? {
        switch state {
        case .resyncing: "Resyncing..."
        case .notPermittedHere: "Not in your permissions"
        case .noTarget: "No target"
        case .missingPlugin: "Plugin missing: value kept"
        case .staleController: "Controller stale"
        case .waitingForPickup: "Waiting for pickup"
        case .pendingRemoval: "Pending removal in draft"
        case .meterUnavailable: signalStatus
        case .engaged, .hazardous: nil
        }
    }

    private var signalStatus: String? {
        guard case .unavailable(let reason) = signal else { return nil }
        return "Signal unavailable: " + reason.performText
    }
}

extension MeterUnavailableReason {
    var performText: String {
        switch self {
        case .faderTravelOnly: "fader travel only"
        case .gated(let gate): gate.performText
        case .neverPublished: "never published"
        case .invalidSlot: "invalid slot"
        case .staleGeneration: "stale generation"
        case .tooOld: "too old"
        case .stale: "stale"
        case .invalidReading: "invalid reading"
        }
    }
}

extension MeterSourceGate {
    var performText: String {
        switch self {
        case .noRoute: "no route"
        case .notMeasured: "not measured"
        case .unmapped: "unmapped"
        case .deviceMissing: "device missing"
        case .lostMuted: "route lost or muted"
        case .sourceRemoved: "source removed"
        case .permissionDenied: "permission denied"
        case .hardwareUnavailable: "hardware unavailable"
        }
    }
}
