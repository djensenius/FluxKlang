//
//  ExplanationFact.swift
//  FluxKlang
//
//  One grounded statement about a `NeutralSnapshot` and the snapshot ids that
//  support it. Statements are fixed phrases plus ASCII ids and enum names;
//  snapshot labels are untrusted text and are never read into a statement.
//

/// A snapshot id a statement or an explanation text relies on.
enum ExplanationCitation: Hashable, Comparable, Sendable {
    case node(NodeID)
    case parameter(ParameterID)
    case route(RouteID)
    case diagnostic(DiagnosticID)

    /// `node`, `parameter`, `route` or `diagnostic`.
    var kindName: String {
        switch self {
        case .node: "node"
        case .parameter: "parameter"
        case .route: "route"
        case .diagnostic: "diagnostic"
        }
    }

    var identifier: String {
        switch self {
        case .node(let id): id.rawValue
        case .parameter(let id): id.rawValue
        case .route(let id): id.rawValue
        case .diagnostic(let id): id.rawValue
        }
    }

    /// The text form `kind:id`, for example `route:rte.000`.
    var reference: String { kindName + ":" + identifier }

    private var kindRank: Int {
        switch self {
        case .node: 0
        case .parameter: 1
        case .route: 2
        case .diagnostic: 3
        }
    }

    /// Orders by kind (node, parameter, route, diagnostic), then by the id's UTF-8 bytes.
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
        return lhs.identifier.utf8.lexicographicallyPrecedes(rhs.identifier.utf8)
    }

    /// Reads `kind:id`; `nil` when the kind is not one of the four (compared by UTF-8 bytes) or the id is not a
    /// valid contract id of that kind.
    static func parse(_ reference: String) -> ExplanationCitation? {
        guard let colon = reference.utf8.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let kind = reference[..<colon].utf8
        let identifier = String(reference[reference.utf8.index(after: colon)...])
        if kind.elementsEqual("node".utf8) { return NodeID(rawValue: identifier).map { .node($0) } }
        if kind.elementsEqual("parameter".utf8) { return ParameterID(rawValue: identifier).map { .parameter($0) } }
        if kind.elementsEqual("route".utf8) { return RouteID(rawValue: identifier).map { .route($0) } }
        if kind.elementsEqual("diagnostic".utf8) { return DiagnosticID(rawValue: identifier).map { .diagnostic($0) } }
        return nil
    }
}

/// A statement the explainer derived from a snapshot. Built only by the explainer's builders below; the
/// statement is compared and hashed by UTF-8 bytes.
struct ExplanationFact: Hashable, Sendable {
    /// Declaration order is the kind order used for sorting.
    enum Kind: Int, Hashable, Sendable, CaseIterable {
        case snapshotTruncated
        case diagnosticOpen
        case routeUnavailable
        case declaredNotMeasured
        case measured
    }

    private(set) var kind: Kind
    /// Set only for `diagnosticOpen`.
    private(set) var severity: DiagnosticSeverity?
    private(set) var citations: [ExplanationCitation]
    private(set) var statement: String

    fileprivate init(
        kind: Kind, severity: DiagnosticSeverity? = nil, citations: [ExplanationCitation], statement: String
    ) {
        self.kind = kind
        self.severity = severity
        self.citations = citations
        self.statement = statement
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.severity == rhs.severity && lhs.citations == rhs.citations
            && lhs.statement.utf8.elementsEqual(rhs.statement.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(severity)
        hasher.combine(citations)
        hasher.combine(statement.utf8.count)
        for byte in statement.utf8 { hasher.combine(byte) }
    }

    /// 0 is the most urgent: truncation and errors, then routes and warnings, declared facts and infos, measured.
    private var urgency: Int {
        switch kind {
        case .snapshotTruncated: 0
        case .diagnosticOpen: severity?.rank ?? 0
        case .routeUnavailable: 1
        case .declaredNotMeasured: 2
        case .measured: 3
        }
    }

    /// The report order: urgency, kind order, citations (kind then id bytes), then statement bytes.
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.urgency != rhs.urgency { return lhs.urgency < rhs.urgency }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.citations != rhs.citations { return lhs.citations.lexicographicallyPrecedes(rhs.citations) }
        return lhs.statement.utf8.lexicographicallyPrecedes(rhs.statement.utf8)
    }
}

extension ExplanationFact {
    /// `measured` only for `.measured`; `.reported` and `.unverified` are declared facts. The parameter's node is
    /// cited and named as a second id only when `snapshot` kept it.
    static func parameter(_ parameter: NeutralSnapshot.Parameter, in snapshot: NeutralSnapshot) -> ExplanationFact {
        var citations = [ExplanationCitation.parameter(parameter.id)]
        var subject = "Parameter " + parameter.id.rawValue
        let node = parameter.node.flatMap { snapshot.node($0) == nil ? nil : $0 }
        if let node {
            citations.append(.node(node))
            subject += " on node " + node.rawValue
        }
        if parameter.verification == .measured {
            return ExplanationFact(
                kind: .measured, citations: citations, statement: subject + " is measured."
            )
        }
        let status = parameter.verification.rawValue
        return ExplanationFact(
            kind: .declaredNotMeasured, citations: citations,
            statement: subject + " is declared only (status " + status + "): it has not been confirmed on a device."
        )
    }

    static func route(_ route: NeutralSnapshot.Route) -> ExplanationFact {
        let presence = route.presence?.rawValue ?? "unobserved"
        var statement = "Route " + route.id.rawValue + " is unavailable: availability " + route.availability.rawValue
        statement += ", binding " + route.binding.rawValue + ", device presence " + presence + "."
        if route.isDeviceWithheld { statement += " Its device identity is withheld." }
        return ExplanationFact(kind: .routeUnavailable, citations: [.route(route.id)], statement: statement)
    }

    /// Cites the diagnostic, and its subject only when the snapshot kept it (a port cites its node; graph and
    /// edge subjects add no citation).
    static func diagnostic(_ diagnostic: NeutralSnapshot.Diagnostic) -> ExplanationFact {
        var citations = [ExplanationCitation.diagnostic(diagnostic.id)]
        var clause = "no subject"
        if let subject = diagnostic.subject {
            if diagnostic.subjectInSnapshot {
                let described = describe(subject)
                clause = described.clause
                if let citation = described.citation { citations.append(citation) }
            } else {
                clause = "subject not in snapshot"
            }
        }
        let statement = "Diagnostic " + diagnostic.id.rawValue + " (severity " + diagnostic.severity.rawValue + "): "
            + clause + "."
        return ExplanationFact(
            kind: .diagnosticOpen, severity: diagnostic.severity, citations: citations, statement: statement
        )
    }

    /// True when the snapshot left something out or altered a label: a cap, a duplicate or a dangling element, an
    /// overflow, or a sanitized label.
    static func isIncomplete(_ truncation: NeutralSnapshot.Truncation) -> Bool {
        let categories = [
            truncation.nodes, truncation.ports, truncation.edges, truncation.parameters, truncation.routes,
            truncation.diagnostics
        ]
        return truncation.isTruncated || truncation.sanitizedLabels > 0 || categories.contains { $0.dropped > 0 }
    }

    /// Cites nothing: it reports counts only.
    static func truncation(_ truncation: NeutralSnapshot.Truncation) -> ExplanationFact {
        let dropped = [
            ("nodes", truncation.nodes), ("ports", truncation.ports), ("edges", truncation.edges),
            ("parameters", truncation.parameters), ("routes", truncation.routes),
            ("diagnostics", truncation.diagnostics)
        ]
        var statement = "The snapshot is incomplete: dropped"
        for (index, entry) in dropped.enumerated() {
            statement += (index == 0 ? " " : ", ") + entry.0 + " " + String(entry.1.dropped)
        }
        statement += "; labels shortened " + String(truncation.truncatedLabels)
        statement += ", labels sanitized " + String(truncation.sanitizedLabels)
        statement += ", withheld overflow " + String(truncation.withheldOverflow)
        statement += ". An id missing from the snapshot may still exist in the setup."
        return ExplanationFact(kind: .snapshotTruncated, citations: [], statement: statement)
    }

    private static func describe(_ subject: DiagnosticSubject) -> (clause: String, citation: ExplanationCitation?) {
        switch subject {
        case .graph:
            ("concerns the graph", nil)
        case .node(let id):
            ("concerns node " + id.rawValue, .node(id))
        case .port(let node, _):
            ("concerns a port of node " + node.rawValue, .node(node))
        case .edge:
            ("concerns an edge", nil)
        case .parameter(let id):
            ("concerns parameter " + id.rawValue, .parameter(id))
        case .route(let id):
            ("concerns route " + id.rawValue, .route(id))
        }
    }
}
