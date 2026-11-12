//
//  WiringConnectionListText.swift
//  FluxKlang
//
//  The fixed English of the compact Connections list (#101 WCL1; phone-compact-routing.md "Three narrow screens"
//  and "States", wiring.md "Node and edge states"): node presence and row badges with their text and VoiceOver
//  labels, the heading's channel or signal text, the short and long conversion text and the accessibility labels.
//  Pure string builders: no localisation, truncation or escaping. `PerformanceWiringListView` shows them (#101 WCL2).
//

/// A destination node's presence on this host, injected by the caller: it comes from this host's rig and session
/// node status, which the graph does not carry. Never assumed: a section without one is refused. Callers must
/// supply it for draft-added nodes too, which the session's `nodeStatus` does not list.
enum WiringNodePresence: Hashable, Sendable, CaseIterable {
    /// Ready or mapped: no badge.
    case ready
    /// The node's role has no route on this host.
    case unmapped
    /// A required capability (the plugin) is missing; the branch stays silent.
    case missing
    /// The routed device went away while running; its outputs are muted.
    case lost

    /// The heading suffix: nil, `Unmapped`, `Missing` or `Lost/Muted`.
    var headingSuffix: String? {
        switch self {
        case .ready: nil
        case .unmapped: "Unmapped"
        case .missing: "Missing"
        case .lost: "Lost/Muted"
        }
    }

    /// The badge's VoiceOver label, as wiring.md's badge table words it; nil when there is no badge.
    var accessibilityText: String? {
        switch self {
        case .ready: nil
        case .unmapped: "Unmapped on this host"
        case .missing: "Missing plugin: branch silent"
        case .lost: "Lost: outputs muted"
        }
    }
}

/// A row's draft badge. `draft` and `willRemove` have a text label and a VoiceOver label; `none` has no text.
/// `Draft` and `Will remove` are wiring.md's badge-table text, `draft, not active` its edge-label wording, and
/// `active, will remove` is this model's own phrase.
enum WiringConnectionBadge: Hashable, Sendable, CaseIterable {
    /// An active edge the review keeps: a plain row.
    case none
    /// An edge the review adds (or the new route of an edge ID it reconnects).
    case draft
    /// An active edge the review removes (or the old route of an edge ID it reconnects): struck through.
    case willRemove

    /// `Draft` or `Will remove`; nil for a plain row.
    var text: String? {
        switch self {
        case .none: nil
        case .draft: "Draft"
        case .willRemove: "Will remove"
        }
    }

    /// The marker that ends the row's accessibility label.
    var accessibilityText: String {
        switch self {
        case .none: WiringInspectorLabel.markerWords(.active)
        case .draft: WiringInspectorLabel.markerWords(.draft)
        case .willRemove: "\(WiringInspectorLabel.markerWords(.active)), will remove"
        }
    }

    var isStruckThrough: Bool { self == .willRemove }

    /// Row order within one source and edge ID: the old route before the new one.
    var rank: Int {
        switch self {
        case .none: 0
        case .willRemove: 1
        case .draft: 2
        }
    }
}

/// Text builders for `WiringConnectionList`.
enum WiringConnectionListText {
    /// A section without rows.
    static let noConnections = "No connections"
    /// The row's feedback marker.
    static let feedback = "fb"
    /// A section whose node has no input port (it is listed only as the destination of an edge).
    static let noInputs = "no inputs"
    /// A map that is not one of `WiringConnectionOffers`' named choices for the pair.
    static let customShort = "map"
    static let customLabel = "Custom channel map"

    /// `2ch`, `audio` (no channel count), `MIDI`, `control` or `clock`.
    static func signalText(_ port: GraphPort) -> String {
        switch port.signal {
        case .audio: port.channels.map { "\($0)ch" } ?? "audio"
        case .midi: "MIDI"
        case .control: "control"
        case .clock: "clock"
        }
    }

    /// `2 channels`, `audio`, `MIDI`, `control` or `clock`.
    static func spokenSignal(_ port: GraphPort) -> String {
        guard port.signal == .audio, let channels = port.channels else { return signalText(port) }
        return WiringInspectorLabel.count(channels, "channel")
    }

    /// The distinct descriptions of the node's input ports in port order, joined by `, `; `no inputs` when it has
    /// none.
    static func inputs(_ node: GraphNode, _ describe: (GraphPort) -> String) -> String {
        var seen = Set<[UInt8]>()
        var texts: [String] = []
        for port in node.ports where port.direction == .input {
            let text = describe(port)
            if seen.insert(Array(text.utf8)).inserted { texts.append(text) }
        }
        return texts.isEmpty ? noInputs : texts.joined(separator: ", ")
    }

    /// The short and long text of `conversion` from a source port of `sourceChannels` (nil when unknown). The long
    /// text is the label of the `WiringConnectionOffers` choice with the same map, never repeated here; the short
    /// text names each side (`mono`, or for two channels `left`, `right` or `both`), as in `mono>both`. Any other
    /// map is `map` / `Custom channel map`.
    static func conversion(_ conversion: EdgeConversion, sourceChannels: Int?) -> (short: String, label: String) {
        guard let sourceChannels,
              let offers = try? WiringConnectionOffers.conversions(
                sourceChannels: sourceChannels, destinationChannels: conversion.map.count
              ),
              let offer = offers.first(where: { $0.conversion.map == conversion.map })
        else { return (customShort, customLabel) }
        let used = Set(conversion.map.joined())
        let filled = Set(conversion.map.indices.filter { !conversion.map[$0].isEmpty })
        return ("\(side(sourceChannels, used))>\(side(conversion.map.count, filled))", offer.label)
    }

    /// The heading: `Mains (2ch)`, or with a presence suffix `Cue (2ch) Unmapped`.
    static func heading(title: String, signal: String, presence: WiringNodePresence) -> String {
        let base = "\(title) (\(signal))"
        return presence.headingSuffix.map { "\(base) \($0)" } ?? base
    }

    /// `Cue, 2 channels, Unmapped on this host, no connections.` or `Mains, 2 channels, 2 connections.`
    static func sectionLabel(title: String, signal: String, presence: WiringNodePresence, rows: Int) -> String {
        let state = presence.accessibilityText.map { ", \($0)" } ?? ""
        let count = rows == 0 ? "no connections" : WiringInspectorLabel.count(rows, "connection")
        return "\(title), \(signal)\(state), \(count)."
    }

    /// The row's line: `Vocal → Mains`, then the short conversion and `fb` when present, space separated.
    static func line(source: String, destination: String, conversion: String?, feedback: String?) -> String {
        ([route(source, destination)] + [conversion, feedback].compactMap { $0 }).joined(separator: " ")
    }

    static func route(_ source: String, _ destination: String) -> String { "\(source) → \(destination)" }

    /// `Vocal to Mains, audio, mono to both sides, active.`: the route (`Vocal to Mains`), the source port's signal
    /// (`audio`, `MIDI`, …), the conversion label with a lower-case first letter or else an audio port's channel
    /// count, then `feedback`, then the badge's marker. A part that is unknown (an unknown port) is left out.
    static func rowLabel(
        route: String, port: GraphPort?, conversion: String?, feedback: Bool, badge: WiringConnectionBadge
    ) -> String {
        var parts = [route]
        if let port {
            parts.append(port.signal == .audio ? "audio" : signalText(port))
            if conversion == nil, port.signal == .audio, let channels = port.channels {
                parts.append(WiringInspectorLabel.count(channels, "channel"))
            }
        }
        if let conversion { parts.append(lowercasedFirst(conversion)) }
        if feedback { parts.append("feedback") }
        parts.append(badge.accessibilityText)
        return parts.joined(separator: ", ") + "."
    }

    private static func side(_ channels: Int, _ used: Set<Int>) -> String {
        if channels == 1 { return "mono" }
        if used == [0] { return "left" }
        if used == [1] { return "right" }
        return "both"
    }

    /// The text with an ASCII upper-case first letter lowered; any other first character is kept.
    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.unicodeScalars.first, (65...90).contains(first.value) else { return text }
        var result = String(Unicode.Scalar(UInt8(first.value + 32)))
        result.unicodeScalars.append(contentsOf: text.unicodeScalars.dropFirst())
        return result
    }
}
