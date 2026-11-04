//
//  NeutralSnapshot+Assembly.swift
//  FluxKlang
//
//  Pure helpers that select, sort and copy contract values into snapshot
//  elements. Selection happens before copying, so work is bounded by the caps.
//

import Foundation

struct NeutralSnapshotAssembly {
    typealias Selection<Element> = (kept: [Element], count: NeutralSnapshot.CategoryCount)

    let limits: NeutralSnapshot.Limits
    /// At most this many distinct withheld strings are collected, enough for four
    /// per route at the default route cap of 256. Past it, `withheldOverflow` is reported.
    static let maximumWithheldCount = 1_024
    /// Device IDs are `ContractID`s of at most 128 bytes, so longer strings can never equal one.
    static let maximumRefusedBytes = 128

    /// Hardware UIDs, host IDs, evidence strings and device IDs refused by the alias
    /// form, known from the inputs and never exposed as a device ID.
    let withheld: [String]
    /// The withheld strings in label match form, prepared once for every label.
    let redacted: [UntrustedTextSanitizer.WithheldTerm]
    /// Distinct withheld strings dropped by `maximumWithheldCount`.
    let withheldOverflow: Int

    init(inputs: NeutralSnapshot.Inputs, limits: NeutralSnapshot.Limits) {
        self.limits = limits
        let (collected, overflow) = Self.collectWithheld(inputs)
        withheldOverflow = overflow
        let trimmed = collected
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.utf8.count <= Self.maximumRefusedBytes }
        withheld = Set(trimmed).sorted()
        redacted = UntrustedTextSanitizer.withheldTerms(collected)
    }

    /// Hardware identifiers first, sorted by their prepared form and then their
    /// raw form in UTF-8 byte order, then each route's `withheldFields` in route-ID
    /// order, with routes sharing an ID ordered by those fields in UTF-8 byte order,
    /// until `maximumWithheldCount` distinct strings are held.
    /// Strings past the cap are neither refused nor redacted; their count is
    /// returned as `overflow` and reported in `Truncation.withheldOverflow`.
    static func collectWithheld(_ inputs: NeutralSnapshot.Inputs) -> (strings: [String], overflow: Int) {
        let hardware = inputs.hardwareIdentifiers
            .map { (key: UntrustedTextSanitizer.withheldTerm($0)?.text ?? "", raw: $0) }
            .sorted { lhs, rhs in
                lhs.key.utf8.elementsEqual(rhs.key.utf8)
                    ? lhs.raw.utf8.lexicographicallyPrecedes(rhs.raw.utf8)
                    : lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
            }
        let routes = inputs.routes.map { (id: $0.route.id, fields: withheldFields(of: $0.route)) }
            .sorted { lhs, rhs in
                lhs.id != rhs.id
                    ? lhs.id < rhs.id
                    : lhs.fields.lexicographicallyPrecedes(rhs.fields) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            }
        var seen = Set<String>()
        var collected: [String] = []
        var overflow = 0
        let add = { (candidate: String) in
            guard seen.insert(candidate).inserted else { return }
            if collected.count < maximumWithheldCount { collected.append(candidate) } else { overflow += 1 }
        }
        hardware.forEach { add($0.raw) }
        routes.forEach { $0.fields.forEach(add) }
        return (collected, overflow)
    }

    /// The route's strings that labels must not show: its device ID when the alias
    /// form refuses it (a withheld route field must not reappear in a label), then
    /// its confirmed UID, host and evidence.
    static func withheldFields(of route: AudioRoute) -> [String] {
        let device = isNeutralDeviceAlias(route.device.rawValue, refused: []) ? nil : route.device.rawValue
        return [device, route.confirmedDeviceUID, route.confirmedHost?.rawValue, route.evidence].compactMap(\.self)
    }

    func label(_ raw: String) -> UntrustedLabel {
        UntrustedLabel(raw, maximumBytes: limits.labelBytes, terms: redacted)
    }

    /// Drops every element whose ID repeats, then every dangling element, then
    /// keeps at most `limit` elements preferring lower `priority` and then lower
    /// ID. The result is sorted by ID.
    static func select<Element, ID: Comparable & Hashable>(
        _ items: [Element], limit: Int, id: (Element) -> ID,
        priority: (Element) -> Int = { _ in 0 }, isDangling: (Element) -> Bool = { _ in false }
    ) -> Selection<Element> {
        var occurrences: [ID: Int] = [:]
        for item in items { occurrences[id(item), default: 0] += 1 }
        let unique = items.filter { occurrences[id($0)] == 1 }
        let attached = unique.filter { !isDangling($0) }
        let cap = max(0, limit)
        var kept = attached
        if attached.count > cap {
            kept = Array(attached.sorted { lhs, rhs in
                let (left, right) = (priority(lhs), priority(rhs))
                return left != right ? left < right : id(lhs) < id(rhs)
            }.prefix(cap))
        }
        kept.sort { id($0) < id($1) }
        let count = NeutralSnapshot.CategoryCount(
            offered: items.count, kept: kept.count, droppedOverLimit: attached.count - kept.count,
            droppedDuplicates: items.count - unique.count, droppedDangling: unique.count - attached.count
        )
        return (kept, count)
    }

    // MARK: - Graph

    func nodes(_ nodes: [GraphNode]) -> Selection<NeutralSnapshot.Node> {
        let selection = Self.select(nodes, limit: limits.nodes, id: \.id)
        let kept = selection.kept.map { node in
            let ports = Self.select(node.ports, limit: limits.portsPerNode, id: \.id)
            return NeutralSnapshot.Node(
                id: node.id, kind: node.kind, label: label(node.label),
                role: node.role, asset: node.asset, graph: node.graph, muted: node.muted,
                ports: ports.kept.map(port), portCount: ports.count
            )
        }
        return (kept, selection.count)
    }

    private func port(_ port: GraphPort) -> NeutralSnapshot.Port {
        NeutralSnapshot.Port(
            id: port.id, direction: port.direction, signal: port.signal, channels: port.channels,
            label: port.label.map(label)
        )
    }

    /// Ports of kept nodes as counted per node; ports of dropped nodes are dangling.
    static func portCount(offered nodes: [GraphNode], kept: [NeutralSnapshot.Node]) -> NeutralSnapshot.CategoryCount {
        let offered = nodes.reduce(0) { $0 + $1.ports.count }
        let keptOffered = kept.reduce(0) { $0 + $1.portCount.offered }
        return NeutralSnapshot.CategoryCount(
            offered: offered,
            kept: kept.reduce(0) { $0 + $1.portCount.kept },
            droppedOverLimit: kept.reduce(0) { $0 + $1.portCount.droppedOverLimit },
            droppedDuplicates: kept.reduce(0) { $0 + $1.portCount.droppedDuplicates },
            droppedDangling: offered - keptOffered
        )
    }

    /// Edges are ranked only when both endpoints are kept ports of kept nodes.
    func edges(_ edges: [GraphEdge], nodes: [NeutralSnapshot.Node]) -> Selection<NeutralSnapshot.Edge> {
        let ports = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set($0.ports.map(\.id))) })
        let isKept = { (address: PortAddress) in ports[address.node]?.contains(address.port) == true }
        let selection = Self.select(edges, limit: limits.edges, id: \.id, isDangling: { edge in
            !isKept(edge.from) || !isKept(edge.to)
        })
        let kept = selection.kept.map { edge in
            NeutralSnapshot.Edge(
                id: edge.id,
                from: NeutralSnapshot.Endpoint(node: edge.from.node, port: edge.from.port),
                to: NeutralSnapshot.Endpoint(node: edge.to.node, port: edge.to.port),
                hasConversion: edge.conversion != nil, isFeedback: edge.feedback != nil
            )
        }
        return (kept, selection.count)
    }

    // MARK: - Parameters and diagnostics

    func parameters(_ parameters: [ParameterDescriptor]) -> Selection<NeutralSnapshot.Parameter> {
        let selection = Self.select(parameters, limit: limits.parameters, id: \.id)
        let kept = selection.kept.map { descriptor in
            let fields = descriptor.fields
            return NeutralSnapshot.Parameter(
                id: fields.id, node: fields.node, unit: fields.unit, lower: fields.lower, upper: fields.upper,
                defaultValue: fields.defaultValue, ceiling: fields.ceiling, curve: fields.curve,
                controlClass: fields.controlClass, verification: fields.verification
            )
        }
        return (kept, selection.count)
    }

    /// Errors win over warnings over info at the cap. A diagnostic whose subject
    /// is not in the snapshot is kept and marked.
    func diagnostics(
        _ records: [NeutralDiagnosticRecord], contains: (DiagnosticSubject) -> Bool
    ) -> Selection<NeutralSnapshot.Diagnostic> {
        let selection = Self.select(records, limit: limits.diagnostics, id: \.id, priority: { $0.severity.rank })
        let kept = selection.kept.map { record in
            NeutralSnapshot.Diagnostic(
                id: record.id, severity: record.severity, summary: label(record.summary),
                subject: record.subject, subjectInSnapshot: record.subject.map(contains) ?? true
            )
        }
        return (kept, selection.count)
    }

    static func labels(
        graph: NeutralSnapshot.GraphIdentity, nodes: [NeutralSnapshot.Node], diagnostics: [NeutralSnapshot.Diagnostic]
    ) -> [UntrustedLabel] {
        var labels = [graph.label].compactMap(\.self)
        for node in nodes {
            labels.append(node.label)
            labels.append(contentsOf: node.ports.compactMap(\.label))
        }
        labels.append(contentsOf: diagnostics.map(\.summary))
        return labels
    }
}
