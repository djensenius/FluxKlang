//
//  WiringImpactSummary.swift
//  FluxKlang
//
//  The one spoken sentence of an edit impact (#101 WPV1): fixed English, decimal counts, a noun singular only at
//  exactly one. Parts are joined by single spaces. `WiringInspectorLabel.problemSummary` is a different phrasing and
//  is not used.
//

enum WiringImpactSummary {
    /// `This edit adds 1 node and moves 2 nodes. Cancels 1 earlier change. 1 new problem.`; the first sentence only
    /// names `added` rows, one clause per kind in heading order, and is left out when no row is added. With no row
    /// at all and no problem introduced or resolved the text starts `No change.`
    static func make(rows: [WiringImpactRow], introduced: Int, resolved: Int) -> String {
        var added = [Int](repeating: 0, count: WiringReviewChangeKind.allCases.count)
        var cancelled = 0
        var revised = 0
        for row in rows {
            switch row.effect {
            case .added: added[row.change.kind.rawValue] += 1
            case .cancelled: cancelled += 1
            case .revised: revised += 1
            }
        }
        var parts: [String] = []
        if rows.isEmpty && introduced == 0 && resolved == 0 { parts.append("No change.") }
        if let sentence = addedSentence(added) { parts.append(sentence) }
        if cancelled > 0 { parts.append("Cancels \(WiringInspectorLabel.count(cancelled, "earlier change")).") }
        if revised > 0 { parts.append("Revises \(WiringInspectorLabel.count(revised, "earlier change")).") }
        parts.append(introduced == 0 ? "No new problems." : "\(WiringInspectorLabel.count(introduced, "new problem")).")
        if resolved > 0 { parts.append("Resolves \(WiringInspectorLabel.count(resolved, "problem")).") }
        return parts.joined(separator: " ")
    }

    private static func addedSentence(_ counts: [Int]) -> String? {
        var clauses: [String] = []
        for kind in WiringReviewChangeKind.allCases where counts[kind.rawValue] > 0 {
            clauses.append(clause(kind, counts[kind.rawValue]))
        }
        guard let last = clauses.last else { return nil }
        if clauses.count == 1 { return "This edit \(last)." }
        return "This edit \(clauses.dropLast().joined(separator: ", ")) and \(last)."
    }

    private static func clause(_ kind: WiringReviewChangeKind, _ number: Int) -> String {
        switch kind {
        case .addedNode: "adds \(WiringInspectorLabel.count(number, "node"))"
        case .movedNode: "moves \(WiringInspectorLabel.count(number, "node"))"
        case .removedNode: "removes \(WiringInspectorLabel.count(number, "node"))"
        case .addedEdge: "adds \(WiringInspectorLabel.count(number, "wire"))"
        case .removedEdge: "removes \(WiringInspectorLabel.count(number, "wire"))"
        }
    }
}
