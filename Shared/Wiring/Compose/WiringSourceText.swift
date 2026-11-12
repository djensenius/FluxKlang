//
//  WiringSourceText.swift
//  FluxKlang
//
//  The fixed English of the Add Connection "From" list (#101 WSRC1; phone-compact-routing.md "Three narrow
//  screens" and "Add Connection flow", wiring.md "observed shortcut"): the observed-shortcut text, the empty
//  text, headings, the next screen's `From:` text and the accessibility labels. Pure string builders: no
//  localisation, truncation or escaping. Nothing calls it yet.
//

/// Text builders for `WiringSourceList`.
enum WiringSourceText {
    /// An observed shortcut's state: the doc's wording, lower case.
    static let observedNotRoutable = "observed, not routable"
    /// The list when no node has an output.
    static let noOutputs = "No outputs"

    /// The port's label, or its raw ID when the label is nil or has no UTF-8 bytes (a whitespace-only label is
    /// kept): the rule of `GraphNode.wiringTitle`.
    static func title(_ port: GraphPort) -> String {
        guard let label = port.label, !label.utf8.isEmpty else { return port.id.rawValue }
        return label
    }

    /// `Mains (2ch)`.
    static func heading(title: String, signal: String) -> String { "\(title) (\(signal))" }

    /// `Console channel 7 (observed, not routable)`.
    static func shortcutHeading(title: String) -> String { "\(title) (\(observedNotRoutable))" }

    /// `1ch audio`, `audio` (no channel count), `MIDI`, `control` or `clock`.
    static func fromSignal(_ port: GraphPort) -> String {
        guard port.signal == .audio, let channels = port.channels else {
            return WiringConnectionListText.signalText(port)
        }
        return "\(channels)ch audio"
    }

    /// `Vocal (1ch audio)`; with the port title after the node title when the node lists several outputs:
    /// `Vocal Aux (1ch audio)`.
    static func fromText(node: String, port: GraphPort, showsPort: Bool) -> String {
        let name = showsPort ? "\(node) \(title(port))" : node
        return "\(name) (\(fromSignal(port)))"
    }

    /// `Vocal, out, audio, 1 channel.`: the node, the port, the signal word and an audio port's channel count.
    static func rowLabel(node: String, port: GraphPort) -> String {
        var parts = [node, title(port), port.signal == .audio ? "audio" : WiringConnectionListText.signalText(port)]
        if port.signal == .audio, let channels = port.channels {
            parts.append(WiringInspectorLabel.count(channels, "channel"))
        }
        return parts.joined(separator: ", ") + "."
    }

    /// `Vocal, 1 channel, 1 output.`
    static func sectionLabel(title: String, signals: String, outputs: Int) -> String {
        "\(title), \(signals), \(WiringInspectorLabel.count(outputs, "output"))."
    }

    /// `Console channel 7, observed, not routable.`
    static func shortcutLabel(title: String) -> String { "\(title), \(observedNotRoutable)." }
}
