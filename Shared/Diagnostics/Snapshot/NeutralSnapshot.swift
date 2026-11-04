//
//  NeutralSnapshot.swift
//  FluxKlang
//
//  A bounded, immutable, read-only view of accepted contract facts (graph,
//  parameters, host routes and diagnostics) used to ground explanations. It is
//  a value only: nothing here constructs commands, drafts or edits, and nothing
//  here reads devices, files or the network.
//

import Foundation

/// An immutable fact base built by `NeutralSnapshot.build(from:limits:)`.
///
/// Every collection is sorted by its stable contract ID and capped by `Limits`;
/// anything left out is counted in `truncation`. Elements whose ID appears more
/// than once in the input are ambiguous and are dropped (and counted), so the
/// result does not depend on input order. Free-form extension fields, hardware
/// UIDs, evidence strings and host bindings are never copied, and known ones are
/// redacted from labels.
struct NeutralSnapshot: Hashable, Sendable, Encodable {
    let limits: Limits
    let project: ProjectIdentity?
    let graph: GraphIdentity
    let nodes: [Node]
    let edges: [Edge]
    let parameters: [Parameter]
    let routes: [Route]
    let diagnostics: [Diagnostic]
    let truncation: Truncation

    /// The pure builder. Equal inputs, in any order, give equal snapshots.
    static func build(from inputs: Inputs, limits: Limits = Limits()) -> NeutralSnapshot {
        NeutralSnapshot(inputs: inputs, limits: limits)
    }

    private init(inputs: Inputs, limits: Limits) {
        let assembly = NeutralSnapshotAssembly(inputs: inputs, limits: limits)
        let nodes = assembly.nodes(inputs.graph.nodes)
        let edges = assembly.edges(inputs.graph.edges, nodes: nodes.kept)
        let parameters = assembly.parameters(inputs.parameters)
        let routes = assembly.routes(inputs.routes)
        let graph = GraphIdentity(id: inputs.graph.id, revision: inputs.graph.revision,
                                  label: inputs.graph.label.map(assembly.label))
        self.limits = limits
        project = inputs.project
        self.graph = graph
        self.nodes = nodes.kept
        self.edges = edges.kept
        self.parameters = parameters.kept
        self.routes = routes.kept
        let diagnostics = assembly.diagnostics(inputs.diagnostics) { subject in
            Self.isPresent(subject, nodes: nodes.kept, edges: edges.kept, parameters: parameters.kept,
                           routes: routes.kept)
        }
        self.diagnostics = diagnostics.kept
        let labels = NeutralSnapshotAssembly.labels(
            graph: graph, nodes: nodes.kept, diagnostics: diagnostics.kept
        )
        truncation = Truncation(
            nodes: nodes.count,
            ports: NeutralSnapshotAssembly.portCount(offered: inputs.graph.nodes, kept: nodes.kept),
            edges: edges.count,
            parameters: parameters.count,
            routes: routes.count,
            diagnostics: diagnostics.count,
            truncatedLabels: labels.count { $0.isTruncated },
            sanitizedLabels: labels.count { $0.wasSanitized },
            withheldOverflow: assembly.withheldOverflow
        )
    }
}

extension NeutralSnapshot {
    /// Per-category caps. Non-positive values are clamped to zero rather than
    /// refused: that category keeps nothing (counted as `droppedOverLimit`) and
    /// a non-positive `labelBytes` yields empty, truncated labels.
    struct Limits: Hashable, Sendable, Encodable {
        var nodes = 512
        var portsPerNode = 256
        var edges = 2_048
        var parameters = 4_096
        var routes = 256
        var diagnostics = 256
        /// Maximum UTF-8 bytes of any label, truncated on a scalar boundary.
        var labelBytes = UntrustedLabel.defaultMaximumBytes
    }

    /// How many elements of one category were offered, kept and dropped.
    struct CategoryCount: Hashable, Sendable, Encodable {
        let offered: Int
        let kept: Int
        /// Unique elements left out because the category reached its cap.
        let droppedOverLimit: Int
        /// Elements left out because their ID appeared more than once.
        let droppedDuplicates: Int
        /// Elements left out because what they attach to is not in the snapshot:
        /// edges whose endpoint port or node was not kept, and ports of dropped nodes.
        let droppedDangling: Int
        /// True when the cap left elements out.
        let isTruncated: Bool

        init(offered: Int, kept: Int, droppedOverLimit: Int, droppedDuplicates: Int, droppedDangling: Int = 0) {
            self.offered = offered
            self.kept = kept
            self.droppedOverLimit = droppedOverLimit
            self.droppedDuplicates = droppedDuplicates
            self.droppedDangling = droppedDangling
            isTruncated = droppedOverLimit > 0
        }

        var dropped: Int { droppedOverLimit + droppedDuplicates + droppedDangling }
    }

    /// What the caps and duplicate rule left out of the snapshot.
    struct Truncation: Hashable, Sendable, Encodable {
        let nodes: CategoryCount
        /// Ports summed over the kept nodes.
        let ports: CategoryCount
        let edges: CategoryCount
        let parameters: CategoryCount
        let routes: CategoryCount
        let diagnostics: CategoryCount
        /// Labels shortened to `Limits.labelBytes`.
        let truncatedLabels: Int
        /// Labels whose characters were replaced, removed, capped or withheld.
        let sanitizedLabels: Int
        /// Distinct withheld strings past `NeutralSnapshotAssembly.maximumWithheldCount`.
        /// They are not redacted, so when this is positive redaction may be incomplete.
        let withheldOverflow: Int

        /// True when any category or label was cut short, or withheld strings overflowed.
        var isTruncated: Bool {
            truncatedLabels > 0 || withheldOverflow > 0
                || [nodes, ports, edges, parameters, routes, diagnostics].contains { $0.isTruncated }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: TruncationCodingKeys.self)
            try container.encode(nodes, forKey: .nodes)
            try container.encode(ports, forKey: .ports)
            try container.encode(edges, forKey: .edges)
            try container.encode(parameters, forKey: .parameters)
            try container.encode(routes, forKey: .routes)
            try container.encode(diagnostics, forKey: .diagnostics)
            try container.encode(truncatedLabels, forKey: .truncatedLabels)
            try container.encode(sanitizedLabels, forKey: .sanitizedLabels)
            try container.encode(withheldOverflow, forKey: .withheldOverflow)
            try container.encode(isTruncated, forKey: .isTruncated)
        }
    }

    /// The project the graph belongs to, by ID and revision only.
    struct ProjectIdentity: Hashable, Sendable, Encodable {
        let id: ProjectID
        let revision: ContractRevision
    }

    struct GraphIdentity: Hashable, Sendable, Encodable {
        let id: GraphID
        let revision: ContractRevision
        let label: UntrustedLabel?
    }

    /// One host route and the presence of its device as last observed, if any.
    struct RouteInput: Hashable, Sendable {
        var route: AudioRoute
        /// `nil` when the host has no observation of the route's device.
        var presence: DevicePresence?
    }

    /// The accepted facts a snapshot is built from.
    struct Inputs: Sendable {
        var graph: GraphDocument
        var parameters: [ParameterDescriptor]
        var routes: [RouteInput]
        var diagnostics: [NeutralDiagnosticRecord]
        var project: ProjectIdentity?
        /// Extra hardware identities (for example device UIDs from a capability
        /// document) to withhold from labels and device IDs, besides the routes'
        /// confirmed UIDs, hosts and evidence.
        var hardwareIdentifiers: [String] = []

        init(graph: GraphDocument, parameters: [ParameterDescriptor] = [], routes: [RouteInput] = [],
             diagnostics: [NeutralDiagnosticRecord] = [], project: ProjectIdentity? = nil) {
            self.graph = graph
            self.parameters = parameters
            self.routes = routes
            self.diagnostics = diagnostics
            self.project = project
        }
    }
}

private enum TruncationCodingKeys: String, CodingKey {
    case nodes, ports, edges, parameters, routes, diagnostics, truncatedLabels, sanitizedLabels, withheldOverflow
    case isTruncated
}
