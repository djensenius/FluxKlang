/// The wiring list's user-facing English (#101). Pure: no SwiftUI, no state. Every edit stays draft-only, so the
/// text keeps saying "Draft" and "Not active".
enum PerformanceWiringText {
    static let heading = "Wiring"
    static let notice = "Draft • Not active. These edits change only this unsaved draft, never live routing."
    static let connectionsHeading = "Connections"
    static let noConnections = "No connections in the draft."
    static let nodesHeading = "Nodes"
    static let addConnection = "Add Connection"
    static let addNode = "Add Node"
    static let removeFromDraft = "Remove from draft"

    /// Only a plain valid pair is selectable: this slice never supplies a conversion or feedback.
    static func isSelectable(_ connectionClass: WiringDestinationClass) -> Bool {
        connectionClass == .valid
    }

    /// Wrong-direction and observed-shortcut destinations are not offered at all (wiring.md "Connection
    /// validation"); every other class stays listed, disabled unless selectable, with its reason.
    static func isListed(_ connectionClass: WiringDestinationClass) -> Bool {
        connectionClass != .notOffered && connectionClass != .notRoutable
    }

    /// The picker's rows, in list order: candidates whose class `isListed`.
    static func listedDestinations(_ list: WiringDestinationList) -> [WiringCandidate] {
        list.candidates.filter { isListed(WiringDestinationClass($0.connection)) }
    }

    static func reason(_ connectionClass: WiringDestinationClass) -> String {
        switch connectionClass {
        case .valid: "Available"
        case .needsConversion: "Not available here: needs a channel conversion"
        case .feedbackOnly: "Not available here: would create a feedback loop"
        case .existing: "Already connected"
        case .disabled: "Not available: signal mismatch"
        case .notOffered: "Not offered: same direction"
        case .notRoutable: "Not offered: observed, not routable"
        case .uncheckable: "Cannot be checked"
        }
    }

    /// The class reason with the pair's own details where the class carries them.
    static func reason(_ connection: WiringConnection) -> String {
        switch connection {
        case .needsConversion(let source, let destination):
            "Not available here: \(source) to \(destination) channels needs a conversion"
        case .disabled(.signalMismatch(let source, let destination)):
            "Not available: \(source.rawValue) cannot feed a \(destination.rawValue) input"
        case .valid, .feedbackOnly, .existing, .notOffered, .notRoutable:
            reason(WiringDestinationClass(connection))
        }
    }

    /// The node's label, or its raw ID when the label is empty or the node is missing (as `WiringInspector` titles).
    static func nodeTitle(_ id: NodeID, in graph: GraphDocument) -> String {
        guard let node = graph.node(id), !node.label.utf8.isEmpty else { return id.rawValue }
        return node.label
    }

    /// `Source: audio output, 2 channels`.
    static func portTitle(_ address: PortAddress, in graph: GraphDocument) -> String {
        let title = nodeTitle(address.node, in: graph)
        guard let port = graph.port(at: address) else { return "\(title): \(address.port.rawValue)" }
        let channels = port.channels.map { ", \(WiringInspectorLabel.count($0, "channel"))" } ?? ""
        return "\(title): \(port.id.rawValue) \(port.direction.rawValue)\(channels)"
    }

    /// `Source to Output`.
    static func connectionTitle(_ edge: GraphEdge, in graph: GraphDocument) -> String {
        "\(nodeTitle(edge.from.node, in: graph)) to \(nodeTitle(edge.to.node, in: graph))"
    }

    static func destinationHeading(_ node: NodeID, in graph: GraphDocument) -> String {
        "To \(nodeTitle(node, in: graph))"
    }

    static func addNodeItem(_ role: ProjectRole) -> String {
        "\(role.label) (\(role.direction.rawValue) role)"
    }

    /// `Output 2`, `Output 3`, …: the smallest number from 2 whose label no node of `graph` has. Starting at 2 keeps
    /// the starter node's own label free for the toggle to restore.
    static func nextLabel(for role: ProjectRole, in graph: GraphDocument) -> String {
        let used = Set(graph.nodes.map(\.label))
        var number = 2
        while used.contains("\(role.label) \(number)") { number += 1 }
        return "\(role.label) \(number)"
    }

    static func removalTitle(_ node: NodeID, in graph: GraphDocument) -> String {
        "Remove \(nodeTitle(node, in: graph)) from the draft?"
    }

    /// Names every connection the removal takes with the node.
    static func removalMessage(_ plan: WiringNodeRemovalPlan, in graph: GraphDocument) -> String {
        guard !plan.edgesToDisconnect.isEmpty else { return "No connections are removed with it. Undo restores it." }
        let names = plan.edgesToDisconnect.map { id in
            graph.edges.first { $0.id == id }.map { connectionTitle($0, in: graph) } ?? id.rawValue
        }
        let count = WiringInspectorLabel.count(names.count, "connection")
        return "Also removes \(count): \(names.joined(separator: "; ")). Undo restores everything."
    }

    static func removalConfirm(_ plan: WiringNodeRemovalPlan) -> String {
        if plan.edgesToDisconnect.isEmpty { return "Remove Node" }
        return "Remove Node and \(WiringInspectorLabel.count(plan.edgesToDisconnect.count, "Connection"))"
    }

    /// The error line's text for a refused edit; unrecognised errors keep their description.
    static func failure(_ error: any Error) -> String {
        switch error {
        case let refusal as WiringComposeRefusal: composeFailure(refusal)
        case WiringEditRefusal.unknownEdge, WiringEditRefusal.notInDraftOrActive:
            "That connection is no longer in the draft"
        case WiringNodeRefusal.nodeAlreadyPresent: "A node with that ID is already in the draft"
        case WiringNodeRefusal.unknownNode: "That node is no longer in the draft"
        case PerformanceProjectSession.WiringRefusal.unknownRole: "That role is not in this project"
        case PerformanceProjectSession.WiringRefusal.staleRemovalPlan:
            "The node's connections changed. Review the removal again"
        case PerformanceProjectSession.EditRefusal.reservedStereoRouteReplacement:
            "The starter connection's endpoints and metadata are fixed"
        default: String(describing: error)
        }
    }

    private static func composeFailure(_ refusal: WiringComposeRefusal) -> String {
        switch refusal {
        case .existing: reason(.existing)
        case .notOffered: reason(WiringDestinationClass.notOffered)
        case .notRoutable: reason(.notRoutable)
        case .disabled(let disabled): reason(.disabled(disabled))
        case .conversionRequired(let source, let destination):
            reason(.needsConversion(sourceChannels: source, destinationChannels: destination))
        case .feedbackRequired: reason(.feedbackOnly)
        case .preview: "The draft changed. Choose the source again"
        case .conversionNotNeeded, .feedbackNotNeeded, .batchInvalid, .connectDoesNotApply:
            String(describing: refusal)
        }
    }
}
