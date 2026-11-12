//
//  WorkspaceInspectorText.swift
//  FluxKlang
//
//  The fixed English of the inspector's selection header (#99 INS1): the empty prompt, kind words, titles, copyable
//  ID text, state texts, the VoiceOver label and the count text. Pure string builders: no localisation, truncation
//  or escaping. Nothing calls it yet.
//

enum WorkspaceInspectorText {
    static let emptyPrompt = "Select a node, edge, speaker or control"

    static func kind(_ item: WorkspaceItemRef) -> String {
        switch item {
        case .node: "Node"
        case .port: "Port"
        case .edge: "Edge"
        }
    }

    static func title(_ item: WorkspaceItemRef) -> String {
        switch item {
        case let .node(node): "Node \(node.rawValue)"
        case let .port(node, port): "Port \(port.rawValue) on node \(node.rawValue)"
        case let .edge(edge): "Edge \(edge.rawValue)"
        }
    }

    /// The secondary, copyable text. A port ID is unique only within its node, so a port reads `<node>/<port>`.
    static func idText(_ item: WorkspaceItemRef) -> String {
        switch item {
        case let .node(node): node.rawValue
        case let .port(node, port): "\(node.rawValue)/\(port.rawValue)"
        case let .edge(edge): edge.rawValue
        }
    }

    /// nil for an active item.
    static func state(_ state: WorkspaceInspectorItemState) -> String? {
        switch state {
        case .active: nil
        case let .draftOnly(activeRevision): "Not in active rev \(activeRevision.description)"
        case let .removed(revision): "Removed in rev \(revision.description)"
        }
    }

    static func accessibilityLabel(title: String, stateText: String?) -> String {
        guard let stateText else { return title }
        return "\(title), \(stateText)"
    }

    static func count(_ count: Int) -> String {
        count == 1 ? "1 item selected" : "\(count) items selected"
    }
}
