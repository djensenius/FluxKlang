//
//  LibraryReplacementRefusal.swift
//  FluxKlang
//
//  Why a replacement plan cannot be made (#101 REP1). A refusal plans nothing and changes nothing. Nothing calls it
//  yet.
//

/// Why `LibraryReplacementPlan.make(replacing:with:as:in:)` is refused. The checks run in the order the cases are
/// declared; the first failing check is the one reported. The one exception is the edit-count bound of `.bounds`,
/// which runs last.
enum LibraryReplacementRefusal: Error, Hashable, Sendable {
    /// A collection exceeds its `ProjectGraphLimits` ceiling: the graph's (`GraphDocument.checkCollectionBounds()`),
    /// then the layout's port count (path `$.replacement.ports`), checked first; and, checked last, the plan's
    /// edit count (path `$.edits`: 2 plus the kept edges, over the limit of one `GraphEdit` batch).
    case bounds(ProjectGraphLimitError)
    /// A node ID repeats (the first repeat in graph order).
    case duplicateNode(NodeID)
    /// The node to replace is not in the graph.
    case unknownNode(NodeID)
    /// The node to replace is not a plugin.
    case notAPlugin(NodeID)
    /// The node to replace declares a port ID twice (the first repeat in port order).
    case duplicatePort(PortAddress)
    /// The replacement's node ID is already a node of the graph, the node to replace included.
    case replacementIDInUse(NodeID)
    /// The layout declares a port ID twice (the first repeat in layout order).
    case duplicateLayoutPort(PortID)
    /// Two edges touching the node to replace share an ID (the first repeat in graph order).
    case duplicateEdge(EdgeID)
}
