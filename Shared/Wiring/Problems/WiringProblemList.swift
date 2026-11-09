//
//  WiringProblemList.swift
//  FluxKlang
//
//  Every distinct problem of a whole wiring graph (#101 WGP1). Each validation error is classified by the
//  inspector's classifier and built into a problem by the impact delta's builder, so the code, the key and the
//  sentence are the ones those two already give. Problems are de-duplicated by key bytes, sorted once by key bytes
//  and capped at 64; the rest are counted, never hidden. Nothing is drawn, focused, edited or sent, and no
//  production code calls this yet.
//

/// One distinct problem of the graph: its fixed sentence and the stop a view should focus.
struct WiringProblemEntry: Hashable, Sendable {
    /// The code, the key and the sentence, exactly as `WiringImpactProblems` builds them.
    let problem: WiringImpactProblem
    /// The node or edge to focus; nil for a problem of the whole graph, of an uncheckable graph or of a hand-made
    /// empty cycle. Never a port.
    let target: WiringSelectionTarget?

    var code: String { problem.code }
    var stableKey: String { problem.stableKey }
    var sentence: String { problem.sentence }

    fileprivate init(problem: WiringImpactProblem, target: WiringSelectionTarget?) {
        self.problem = problem
        self.target = target
    }
}

/// The distinct problems of one graph, smallest key bytes first, at most `maximumEntries` of them. Built only by
/// `make(errors:)`, `make(graph:)` and `make(active:draft:)`.
struct WiringProblemList: Hashable, Sendable {
    /// The most entries one list carries; the rest are counted in `omittedCount`.
    static let maximumEntries = 64

    /// The first `maximumEntries` distinct problems in key order.
    let entries: [WiringProblemEntry]
    /// How many distinct problems there are, shown or not.
    let distinctCount: Int
    /// How many distinct problems the cap left out: the last ones in key order.
    let omittedCount: Int

    var isEmpty: Bool { entries.isEmpty }

    private struct KeyedEntry {
        let key: [UInt8]
        let entry: WiringProblemEntry
    }

    private init(entries: [WiringProblemEntry], distinctCount: Int, omittedCount: Int) {
        self.entries = entries
        self.distinctCount = distinctCount
        self.omittedCount = omittedCount
    }

    /// The distinct problems of `errors`, which may repeat and may come in any order. Total: it never refuses.
    /// One pass classifies each error, builds its problem and inserts its key bytes into one set (expected O(1)
    /// per error and per key byte); one sort of the distinct problems follows, then the cap. Keys are compared as
    /// bytes, so two details that differ only in Unicode normalisation stay two problems.
    static func make(errors: [GraphValidationError]) -> WiringProblemList {
        var seen = Set<[UInt8]>()
        seen.reserveCapacity(errors.count)
        var kept: [KeyedEntry] = []
        for error in errors {
            let classification = WiringInspectorProblem.classify(error)
            let problem = WiringImpactProblems.problem(classification)
            let key = Array(problem.stableKey.utf8)
            guard seen.insert(key).inserted else { continue }
            let target = focusTarget(of: classification.scope)
            kept.append(KeyedEntry(key: key, entry: WiringProblemEntry(problem: problem, target: target)))
        }
        kept.sort { $0.key.lexicographicallyPrecedes($1.key) }
        let shown = kept.prefix(maximumEntries).map(\.entry)
        return WiringProblemList(entries: shown, distinctCount: kept.count, omittedCount: kept.count - shown.count)
    }

    /// The distinct problems of `graph`, from its validation errors in non-strict mode, computed once. A graph the
    /// contract cannot check (past its limits, or with bad required features) lists its one uncheckable error as
    /// a problem of the whole graph; it is not refused.
    static func make(graph: GraphDocument) -> WiringProblemList {
        make(errors: graph.validationErrors())
    }

    /// The distinct problems of the graph `draft` makes of `active`. The draft graph is made first, with the same
    /// refusals as `WiringDraftGraph.make(active:draft:)`, carried verbatim; the validation errors come after.
    static func make(active: GraphDocument, draft: DraftEdits) throws(WiringProblemListRefusal) -> WiringProblemList {
        let draftGraph: WiringDraftGraph
        do {
            draftGraph = try WiringDraftGraph.make(active: active, draft: draft)
        } catch {
            throw .preview(error)
        }
        return make(graph: draftGraph.graph)
    }

    /// The stop a view should focus for a problem of `scope`: a node for a node, an edge for an edge, the node with
    /// the least ID bytes for a cycle, and nil for the whole graph, an uncheckable graph or a hand-made empty cycle.
    /// Never a port. It does not check that the stop exists in a `WiringSelectionOrder`, which refuses a graph that
    /// repeats a node, port or edge: the caller checks, and falls back to no focus.
    static func focusTarget(of scope: WiringInspectorScope) -> WiringSelectionTarget? {
        switch scope {
        case .node(let id): return .node(id)
        case .edge(let id): return .edge(id)
        case .nodes(let ids):
            guard let least = leastNode(ids) else { return nil }
            return .node(least)
        case .graph, .uncheckable: return nil
        }
    }

    /// The node with the least ID bytes, found in one pass; nil for an empty list.
    private static func leastNode(_ ids: [NodeID]) -> NodeID? {
        guard var least = ids.first else { return nil }
        for id in ids.dropFirst() where id.rawValue.utf8.lexicographicallyPrecedes(least.rawValue.utf8) {
            least = id
        }
        return least
    }
}
