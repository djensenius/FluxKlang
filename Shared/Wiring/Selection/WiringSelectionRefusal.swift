//
//  WiringSelectionRefusal.swift
//  FluxKlang
//
//  Why a wiring focus order cannot be built (#101 WSL1). A refusal builds nothing and changes nothing.
//

/// Why a focus order is refused. `make(graph:)` checks, in this order: `tooManyNodes`, `tooManyEdges`,
/// `tooManyPorts`, `duplicateNode`, `duplicatePort`, `duplicateEdge`. `make(active:draft:)` checks `preview` first.
enum WiringSelectionRefusal: Error, Hashable, Sendable {
    /// The graph has more than `ProjectGraphLimits.nodes` nodes.
    case tooManyNodes(Int)
    /// The graph has more than `ProjectGraphLimits.edges` edges.
    case tooManyEdges(Int)
    /// The first node, in the graph's own order, with more than `ProjectGraphLimits.portsPerNode` ports.
    case tooManyPorts(node: NodeID, count: Int)
    /// The first node ID that repeats, in the graph's own order.
    case duplicateNode(NodeID)
    /// The first port ID that repeats within its node (nodes in graph order, ports in declared order).
    case duplicatePort(node: NodeID, port: PortID)
    /// The first edge ID that repeats, in the graph's own order.
    case duplicateEdge(EdgeID)
    /// The draft does not check against the active graph.
    case preview(WiringPreviewRefusal)
}
