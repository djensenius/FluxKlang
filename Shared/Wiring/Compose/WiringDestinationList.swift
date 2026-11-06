//
//  WiringDestinationList.swift
//  FluxKlang
//
//  Every destination of one source port, classified bare (no conversion, no
//  feedback) and grouped by connection class. Groups follow
//  `WiringDestinationClass` order and only non-empty groups are present; within a
//  group destinations are sorted by (node ID, port ID) raw value, so the list
//  is the same whatever the graph's node or port order.
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

/// One heading of the list: every destination of a class, sorted by (node ID, port ID). Never empty.
struct WiringDestinationGroup: Hashable, Sendable {
    private(set) var connectionClass: WiringDestinationClass
    private(set) var candidates: [WiringCandidate]

    fileprivate init(connectionClass: WiringDestinationClass, candidates: [WiringCandidate]) {
        self.connectionClass = connectionClass
        self.candidates = candidates
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

    /// Every destination, group by group.
    var candidates: [WiringCandidate] { groups.flatMap(\.candidates) }

    /// The group of `connectionClass`, or `nil` when no destination has it.
    func group(_ connectionClass: WiringDestinationClass) -> WiringDestinationGroup? {
        groups.first { $0.connectionClass == connectionClass }
    }

    /// Classifies `source` → every other port of `graph` (each address once). The source must
    /// name a node of the graph and, on a routable node, one of its ports.
    static func make(
        from source: PortAddress, in graph: GraphDocument
    ) throws(WiringPreviewRefusal) -> WiringDestinationList {
        guard let node = graph.node(source.node) else { throw .unknownNode(source.node) }
        guard !node.kind.isRoutable || node.port(source.port) != nil else { throw .unknownPort(source) }
        let addresses = Set(graph.nodes.flatMap { node in
            node.ports.map { PortAddress(node: node.id, port: $0.id) }
        }).subtracting([PortAddress(node: source.node, port: source.port)])
        let ordered = addresses.sorted { lhs, rhs in
            (lhs.node.rawValue, lhs.port.rawValue) < (rhs.node.rawValue, rhs.port.rawValue)
        }
        var byClass: [WiringDestinationClass: [WiringCandidate]] = [:]
        for destination in ordered {
            let candidate = try WiringCandidate.classify(from: source, to: destination, in: graph)
            byClass[WiringDestinationClass(candidate.connection), default: []].append(candidate)
        }
        let groups = WiringDestinationClass.allCases.compactMap { connectionClass -> WiringDestinationGroup? in
            guard let candidates = byClass[connectionClass], !candidates.isEmpty else { return nil }
            return WiringDestinationGroup(connectionClass: connectionClass, candidates: candidates)
        }
        return WiringDestinationList(source: source, groups: groups)
    }
}
