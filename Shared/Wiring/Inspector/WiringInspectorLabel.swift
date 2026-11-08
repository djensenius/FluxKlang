//
//  WiringInspectorLabel.swift
//  FluxKlang
//
//  The fixed English sentences and accessibility labels of the wiring inspector (#101 WIN1). Pure string builders:
//  counts are written in decimal without grouping, and a noun is singular only at exactly one.
//

/// Sentence and label builders for `WiringInspector`. There is no localisation, truncation or escaping.
enum WiringInspectorLabel {
    /// What a node's label states, as plain values.
    struct NodeFacts: Hashable, Sendable {
        let title: String
        let kind: NodeKind
        let marker: WiringInspectorMarker
        let inputs: Int
        let outputs: Int
        let connections: Int
        let feedback: Int
        let problems: Int
    }

    /// `1 input`, `2 inputs`, `0 inputs`.
    static func count(_ number: Int, _ singular: String) -> String {
        number == 1 ? "1 \(singular)" : "\(number) \(singular)s"
    }

    /// `No problems.`, `1 problem.`, `N problems.`.
    static func problemSummary(_ number: Int) -> String {
        if number == 0 { return "No problems." }
        return "\(count(number, "problem"))."
    }

    static func markerWords(_ marker: WiringInspectorMarker) -> String {
        switch marker {
        case .active: return "active"
        case .draft: return "draft, not active"
        }
    }

    /// The code with each ASCII upper-case letter turned into a space and its lower-case form.
    static func words(_ code: String) -> String {
        var text = ""
        for scalar in code.unicodeScalars {
            if (65...90).contains(scalar.value) {
                text.unicodeScalars.append(" ")
                text.unicodeScalars.append(Unicode.Scalar(UInt8(scalar.value + 32)))
            } else {
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    /// `{prefix}: {words}{ detail}.`; the space and the detail are left out when the detail is empty.
    static func sentence(prefix: String, code: String, detail: String) -> String {
        let spoken = words(code)
        if detail.utf8.isEmpty { return "\(prefix): \(spoken)." }
        return "\(prefix): \(spoken) \(detail)."
    }

    static func node(_ facts: NodeFacts) -> String {
        let headline = "\(facts.title), \(facts.kind.rawValue), \(markerWords(facts.marker))."
        let ports = "\(count(facts.inputs, "input")), \(count(facts.outputs, "output"))."
        let wires = "\(count(facts.connections, "connection")), \(facts.feedback) feedback."
        let observed = facts.kind.isRoutable ? "" : "Observed, not routable. "
        return "\(headline) \(ports) \(wires) \(observed)\(problemSummary(facts.problems))"
    }

    static func edge(from source: WiringInspectorEnd, to destination: WiringInspectorEnd,
                     marker: WiringInspectorMarker, problems: Int) -> String {
        let route = "\(endText(source)) to \(endText(destination)), \(markerWords(marker))."
        return "\(route) \(problemSummary(problems))"
    }

    private static func endText(_ end: WiringInspectorEnd) -> String {
        switch end.state {
        case .missingNode: return "\(end.title) (missing)"
        case .notRoutable, .missingPort, .connected: return end.title
        }
    }
}
