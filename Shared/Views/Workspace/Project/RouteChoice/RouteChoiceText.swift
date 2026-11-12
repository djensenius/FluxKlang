//
//  RouteChoiceText.swift
//  FluxKlang
//
//  The fixed English of the compact route picker's list (#100 MAP1; phone-compact-routing.md "Map..." picker). Pure
//  string builders: no localisation, truncation or escaping. The state and accessibility wording is provisional:
//  the document has none for it. Nothing calls it yet.
//

enum RouteChoiceText {
    /// The document's line, verbatim.
    static let footnote = "Other hosts' devices are never listed (rigs are not synced)"
    static let empty = "No compatible channels on the devices that are present"
    static let available = "available"

    /// "Map <role label> (<N>ch)".
    static func headline(roleLabel: String, channelCount: Int) -> String {
        "Map \(roleLabel) (\(channelCount)ch)"
    }

    /// "In" or "Out", then the 1-based block: "Out 1" or "Out 1-2".
    static func channels(direction: RouteDirection, firstChannel: Int, channelCount: Int) -> String {
        let word = direction == .input ? "In" : "Out"
        let first = firstChannel + 1
        guard channelCount > 1 else { return "\(word) \(first)" }
        return "\(word) \(first)-\(firstChannel + channelCount)"
    }

    static func state(_ state: RouteChoiceState, labels: [String]) -> String {
        switch state {
        case .available: available
        case .outputInUse: "in use by \(labels.joined(separator: ", "))"
        case .sharedInput: "also read by \(labels.joined(separator: ", "))"
        }
    }

    /// `omitted` counts compatible blocks (one picker row each), so the unit is the picker's own word, "choice".
    static func truncation(omitted: Int) -> String {
        omitted == 1
            ? "1 more compatible choice is not listed"
            : "\(omitted) more compatible choices are not listed"
    }

    /// "<name>, <channels>, <state>", plus ", not selectable" for a disabled row.
    static func accessibilityLabel(name: String, channels: String, state: String, isEnabled: Bool) -> String {
        let label = "\(name), \(channels), \(state)"
        return isEnabled ? label : "\(label), not selectable"
    }
}
