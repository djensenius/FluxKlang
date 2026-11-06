//
//  WiringDestinationList.swift
//  FluxKlang
//
//  Every destination of one source port, classified bare (no conversion, no
//  feedback) and grouped by connection class. Groups follow
//  `WiringDestinationClass` order and only non-empty groups are present; within a
//  group destinations are sorted by (node ID, port ID) raw value, so the list
//  is the same whatever the graph's node or port order. A destination the
//  classifier refuses on its own account is listed under `.uncheckable`; only
//  source- and graph-level refusals refuse the whole list.
//
//  Cost: one `WiringCandidateBatch` (one baseline validation and indexes, O(nodes
//  + ports + edges)), a sort of the P destinations (O(P log P)) and O(1) expected
//  work per destination, plus, once per destination node that reaches the cycle
//  rule, a search of the linked graph (O(nodes + edges)). That last term is at
//  most O(nodes × (nodes + edges)), and only when most nodes feed the source;
//  the `feedbackOnly` cycle lists themselves can then total O(nodes²).
//

/// The heading a destination is listed under, in list order.
enum WiringDestinationClass: Int, Hashable, Sendable, Comparable, CaseIterable {
    case valid
    case needsConversion
    case feedbackOnly
    case existing
    case disabled
    case notOffered
    case notRoutable
    /// The classifier refused this pair alone (for example `.endpointUncheckable` for a node whose
    /// channel counts are unconfirmed); no `WiringConnection` maps here.
    case uncheckable

    /// The heading of `connection`.
    init(_ connection: WiringConnection) {
        switch connection {
        case .valid: self = .valid
        case .needsConversion: self = .needsConversion
        case .feedbackOnly: self = .feedbackOnly
        case .existing: self = .existing
        case .disabled: self = .disabled
        case .notOffered: self = .notOffered
        case .notRoutable: self = .notRoutable
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A destination whose pair the classifier refused on its own account. Built only by the list.
struct WiringUncheckableDestination: Hashable, Sendable {
    private(set) var from: PortAddress
    private(set) var to: PortAddress
    /// Exactly what `WiringCandidate.classify(from:to:in:)` throws for the pair.
    private(set) var refusal: WiringPreviewRefusal

    fileprivate init(from: PortAddress, to: PortAddress, refusal: WiringPreviewRefusal) {
        self.from = from
        self.to = to
        self.refusal = refusal
    }
}

/// One heading of the list: every destination of a class, sorted by (node ID, port ID). Never empty:
/// `.uncheckable` has only `uncheckable` rows, every other class only `candidates`.
struct WiringDestinationGroup: Hashable, Sendable {
    private(set) var connectionClass: WiringDestinationClass
    private(set) var candidates: [WiringCandidate]
    private(set) var uncheckable: [WiringUncheckableDestination]

    fileprivate init(
        connectionClass: WiringDestinationClass, candidates: [WiringCandidate],
        uncheckable: [WiringUncheckableDestination] = []
    ) {
        self.connectionClass = connectionClass
        self.candidates = candidates
        self.uncheckable = uncheckable
    }
}

/// Every destination of one source port in one graph, grouped by connection class.
struct WiringDestinationList: Hashable, Sendable {
    private(set) var source: PortAddress
    /// Groups in `WiringDestinationClass` order; classes without destinations are omitted.
    private(set) var groups: [WiringDestinationGroup]

    private init(source: PortAddress, groups: [WiringDestinationGroup]) {
        self.source = source
        self.groups = groups
    }

    /// Every classified destination, group by group (the `.uncheckable` rows are not candidates).
    var candidates: [WiringCandidate] { groups.flatMap(\.candidates) }

    /// The group of `connectionClass`, or `nil` when no destination has it.
    func group(_ connectionClass: WiringDestinationClass) -> WiringDestinationGroup? {
        groups.first { $0.connectionClass == connectionClass }
    }

    /// Classifies `source` → every other port of `graph` (each address once). Refused as a whole only
    /// for the source or the graph: bounds, an unknown source node or (on a routable node) port, a graph
    /// the contract cannot check, an uncheckable source node, or a graph already at the edge bound.
    static func make(
        from source: PortAddress, in graph: GraphDocument
    ) throws(WiringPreviewRefusal) -> WiringDestinationList {
        try make(from: source, in: graph) { $0.validationErrors() }
    }

    /// `make(from:in:)` with the baseline validation supplied; it is called exactly once (a test seam).
    static func make(
        from source: PortAddress, in graph: GraphDocument, validate: (GraphDocument) -> [GraphValidationError]
    ) throws(WiringPreviewRefusal) -> WiringDestinationList {
        // The batch checks the graph's bounds before any port is collected.
        var batch = try WiringCandidateBatch(from: source, in: graph, validate: validate)
        let addresses = Set(graph.nodes.flatMap { node in
            node.ports.map { PortAddress(node: node.id, port: $0.id) }
        }).subtracting([PortAddress(node: source.node, port: source.port)])
        let ordered = addresses.sorted { lhs, rhs in
            (lhs.node.rawValue, lhs.port.rawValue) < (rhs.node.rawValue, rhs.port.rawValue)
        }
        var byClass: [WiringDestinationClass: [WiringCandidate]] = [:]
        var uncheckable: [WiringUncheckableDestination] = []
        for destination in ordered {
            do {
                let candidate = try batch.classify(to: destination)
                byClass[WiringDestinationClass(candidate.connection), default: []].append(candidate)
            } catch {
                uncheckable.append(WiringUncheckableDestination(from: source, to: destination, refusal: error))
            }
        }
        var groups = WiringDestinationClass.allCases.compactMap { connectionClass -> WiringDestinationGroup? in
            guard let candidates = byClass[connectionClass], !candidates.isEmpty else { return nil }
            return WiringDestinationGroup(connectionClass: connectionClass, candidates: candidates)
        }
        if !uncheckable.isEmpty {
            groups.append(
                WiringDestinationGroup(connectionClass: .uncheckable, candidates: [], uncheckable: uncheckable)
            )
        }
        return WiringDestinationList(source: source, groups: groups)
    }
}
