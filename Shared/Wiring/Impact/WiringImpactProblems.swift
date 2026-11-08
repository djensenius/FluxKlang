//
//  WiringImpactProblems.swift
//  FluxKlang
//
//  The problems one gesture introduces or resolves (#101 WPV1). Each validation error of the draft graph before and
//  after is classified by the inspector's classifier, keyed by its code, scope and detail, and compared by key. A
//  problem present on both sides is in neither list, so a gesture never "introduces" a baseline problem.
//

/// One problem a gesture introduces or resolves. Built only by `WiringImpactProblems`.
struct WiringImpactProblem: Hashable, Sendable {
    /// The case name of the validation error.
    let code: String
    /// `code`, scope and detail, each part followed by a NUL (U+0000) separator except the last; the scope reads
    /// `node:<id>`, `nodes:<id>,<id>`, `edge:<id>`, `graph` or `uncheckable`. Equal keys name the same problem.
    let stableKey: String
    /// One fixed English sentence with raw IDs, from `WiringInspectorLabel.sentence`.
    let sentence: String

    fileprivate init(code: String, stableKey: String, sentence: String) {
        self.code = code
        self.stableKey = stableKey
        self.sentence = sentence
    }
}

/// The problem delta between the validation errors before and after a gesture.
enum WiringImpactProblems {
    /// The problems only after (`introduced`) and only before (`resolved`), each sorted by key bytes.
    struct Delta: Hashable, Sendable {
        let introduced: [WiringImpactProblem]
        let resolved: [WiringImpactProblem]
    }

    /// No problem introduced and none resolved.
    static let unchanged = Delta(introduced: [], resolved: [])

    private struct KeyedProblem {
        let key: [UInt8]
        let classification: WiringInspectorProblem.Classification
    }

    static func delta(before: [GraphValidationError], after: [GraphValidationError]) -> Delta {
        let earlier = indexed(before)
        let later = indexed(after)
        var introduced: [KeyedProblem] = []
        for (key, classification) in later where earlier[key] == nil {
            introduced.append(KeyedProblem(key: key, classification: classification))
        }
        var resolved: [KeyedProblem] = []
        for (key, classification) in earlier where later[key] == nil {
            resolved.append(KeyedProblem(key: key, classification: classification))
        }
        return Delta(introduced: sortedProblems(introduced), resolved: sortedProblems(resolved))
    }

    /// The problem of one classified error: its key and its sentence.
    static func problem(_ classification: WiringInspectorProblem.Classification) -> WiringImpactProblem {
        WiringImpactProblem(
            code: classification.code,
            stableKey: stableKey(classification),
            sentence: WiringInspectorLabel.sentence(
                prefix: prefix(classification.scope), code: classification.code, detail: classification.detail
            )
        )
    }

    private static func indexed(
        _ errors: [GraphValidationError]
    ) -> [[UInt8]: WiringInspectorProblem.Classification] {
        var byKey: [[UInt8]: WiringInspectorProblem.Classification] = [:]
        byKey.reserveCapacity(errors.count)
        for error in errors {
            let classification = WiringInspectorProblem.classify(error)
            let key = Array(stableKey(classification).utf8)
            if byKey[key] == nil { byKey[key] = classification }
        }
        return byKey
    }

    private static func sortedProblems(_ keyed: [KeyedProblem]) -> [WiringImpactProblem] {
        var ordered = keyed
        ordered.sort { $0.key.lexicographicallyPrecedes($1.key) }
        return ordered.map { problem($0.classification) }
    }

    private static func stableKey(_ classification: WiringInspectorProblem.Classification) -> String {
        "\(classification.code)\u{0}\(scopeText(classification.scope))\u{0}\(classification.detail)"
    }

    /// A `ContractID` is 1 to 128 characters of `[A-Za-z0-9._:-]`, so a comma (and a NUL) cannot occur in an ID and
    /// two different cycles cannot produce the same joined text.
    private static func scopeText(_ scope: WiringInspectorScope) -> String {
        switch scope {
        case .node(let id): "node:\(id.rawValue)"
        case .nodes(let ids): "nodes:\(ids.map(\.rawValue).joined(separator: ","))"
        case .edge(let id): "edge:\(id.rawValue)"
        case .graph: "graph"
        case .uncheckable: "uncheckable"
        }
    }

    private static func prefix(_ scope: WiringInspectorScope) -> String {
        switch scope {
        case .node(let id): "Node \(id.rawValue)"
        case .nodes(let ids): "Cycle \(ids.map(\.rawValue).joined(separator: " "))"
        case .edge(let id): "Wire \(id.rawValue)"
        case .graph, .uncheckable: "Graph"
        }
    }
}
