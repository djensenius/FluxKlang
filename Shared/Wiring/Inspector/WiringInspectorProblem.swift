//
//  WiringInspectorProblem.swift
//  FluxKlang
//
//  The contract diagnostics that concern one selected node or edge (#101 WIN1): each error of the draft graph is
//  classified by the first payload of its case, kept only when it concerns the selection, given a stable ID and a
//  sentence, then ordered and de-duplicated.
//

/// What a validation error is about, taken from the first payload of its case.
enum WiringInspectorScope: Hashable, Sendable {
    case node(NodeID)
    case nodes([NodeID])
    case edge(EdgeID)
    case graph
    case uncheckable
}

/// One contract diagnostic that concerns the selection. Built only by `problems(_:subject:attached:title:)`.
struct WiringInspectorProblem: Hashable, Sendable {
    /// The code, the scope and the detail text of one validation error.
    struct Classification: Hashable, Sendable {
        let code: String
        let scope: WiringInspectorScope
        let detail: String
    }

    /// The case name of the validation error.
    let code: String
    /// `code|primary|detail`: primary is the node or edge raw ID the problem is listed under (for a cycle, the
    /// subject node); detail is empty when the case has none.
    let stableID: String
    let sentence: String

    fileprivate init(code: String, stableID: String, sentence: String) {
        self.code = code
        self.stableID = stableID
        self.sentence = sentence
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func classify(_ error: GraphValidationError) -> Classification {
        switch error {
        case .bounds: return entry("bounds", .uncheckable)
        case .reviewRequired: return entry("reviewRequired", .graph)
        case .invalidRequiredFeatures: return entry("invalidRequiredFeatures", .uncheckable)
        case .requiredFeaturesCollision: return entry("requiredFeaturesCollision", .uncheckable)
        case .invalidMuteState(let node): return entry("invalidMuteState", .node(node))
        case .invalidMuteShape(let node): return entry("invalidMuteShape", .node(node))
        case .invalidGainState(let node): return entry("invalidGainState", .node(node))
        case .invalidGainValue(let node): return entry("invalidGainValue", .node(node))
        case .invalidGainShape(let node): return entry("invalidGainShape", .node(node))
        case .invalidPosition(let node): return entry("invalidPosition", .node(node))
        case .duplicateNode(let node): return entry("duplicateNode", .node(node))
        case .duplicatePort(let node, let port): return entry("duplicatePort", .node(node), port.rawValue)
        case .duplicateEdge(let edge): return entry("duplicateEdge", .edge(edge))
        case .duplicateWire(let edge): return entry("duplicateWire", .edge(edge))
        case .duplicateCapability(let capability): return entry("duplicateCapability", .graph, capability.rawValue)
        case .undefinedCapability(let node, let capability):
            return entry("undefinedCapability", .node(node), capability.rawValue)
        case .unsupportedRequiredCapability(let node, let capability):
            return entry("unsupportedRequiredCapability", .node(node), capability.rawValue)
        case .conflictingCapabilityLevel(let node, let capability):
            return entry("conflictingCapabilityLevel", .node(node), capability.rawValue)
        case .nonRoutableNodeHasPorts(let node): return entry("nonRoutableNodeHasPorts", .node(node))
        case .missingReference(let node, let field): return entry("missingReference", .node(node), field)
        case .invalidChannelCount(let node, let port): return entry("invalidChannelCount", .node(node), port.rawValue)
        case .missingNode(let edge, let node): return entry("missingNode", .edge(edge), node.rawValue)
        case .missingPort(let edge, let address):
            return entry("missingPort", .edge(edge), "\(address.node.rawValue)/\(address.port.rawValue)")
        case .wrongDirection(let edge): return entry("wrongDirection", .edge(edge))
        case .signalMismatch(let edge, let source, let destination):
            return entry("signalMismatch", .edge(edge), "\(source.rawValue) to \(destination.rawValue)")
        case .channelMismatch(let edge, let source, let destination):
            return entry("channelMismatch", .edge(edge), "\(source) to \(destination)")
        case .invalidConversion(let edge): return entry("invalidConversion", .edge(edge))
        case .invalidFeedback(let edge): return entry("invalidFeedback", .edge(edge))
        case .cycleWithoutFeedback(let nodes): return entry("cycleWithoutFeedback", .nodes(nodes))
        case .unknownFields(let path): return entry("unknownFields", .graph, path)
        }
    }

    /// The problems of `errors` that concern `subject`, sorted by `stableID` (UTF-8 bytes, ascending) with equal
    /// stable IDs collapsed. `attached` are the edge IDs attached to a node subject (empty for an edge subject);
    /// `title` is the subject's title, used in the sentences of node and cycle problems. `attached` is turned into a
    /// set once, so matching an edge error to the node is an expected O(1) lookup per error.
    static func problems(
        _ errors: [GraphValidationError], subject: WiringInspectorSubject, attached: [EdgeID], title: String
    ) -> [WiringInspectorProblem] {
        let attachedSet = Set(attached)
        var found: [WiringInspectorProblem] = []
        for error in errors {
            let parts = classify(error)
            guard let owner = owner(of: parts.scope, subject: subject, attached: attachedSet) else { continue }
            found.append(problem(parts, owner: owner, title: title))
        }
        found.sort { $0.stableID.utf8.lexicographicallyPrecedes($1.stableID.utf8) }
        var unique: [WiringInspectorProblem] = []
        for item in found {
            if let last = unique.last, last.stableID.utf8.elementsEqual(item.stableID.utf8) { continue }
            unique.append(item)
        }
        return unique
    }

    private enum Owner {
        case wire(String)
        case node(String)
    }

    private static func entry(_ code: String, _ scope: WiringInspectorScope, _ detail: String = "") -> Classification {
        Classification(code: code, scope: scope, detail: detail)
    }

    private static func owner(
        of scope: WiringInspectorScope, subject: WiringInspectorSubject, attached: Set<EdgeID>
    ) -> Owner? {
        switch (subject, scope) {
        case (.node(let own), .node(let other)): return own == other ? .node(own.rawValue) : nil
        case (.node(let own), .nodes(let cycle)): return cycle.contains(own) ? .node(own.rawValue) : nil
        case (.node, .edge(let edge)): return attached.contains(edge) ? .wire(edge.rawValue) : nil
        case (.edge(let own), .edge(let other)): return own == other ? .wire(own.rawValue) : nil
        case (.node, .graph), (.node, .uncheckable), (.edge, .node), (.edge, .nodes),
             (.edge, .graph), (.edge, .uncheckable):
            return nil
        }
    }

    private static func problem(_ parts: Classification, owner: Owner, title: String) -> WiringInspectorProblem {
        let primary: String
        let prefix: String
        switch owner {
        case .wire(let edge):
            primary = edge
            prefix = "Wire \(edge)"
        case .node(let node):
            primary = node
            prefix = "Node \(title)"
        }
        return WiringInspectorProblem(
            code: parts.code,
            stableID: "\(parts.code)|\(primary)|\(parts.detail)",
            sentence: WiringInspectorLabel.sentence(prefix: prefix, code: parts.code, detail: parts.detail)
        )
    }
}
