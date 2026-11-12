//
//  WiringSourceListRefusal.swift
//  FluxKlang
//
//  Why the Add Connection "From" list cannot be made (#101 WSRC1). A refusal lists nothing. Nothing calls it yet.
//

/// Why `WiringSourceList.make(in:)` is refused. The checks run in the order the cases are declared; the first
/// failing check is the one reported.
enum WiringSourceListRefusal: Error, Hashable, Sendable {
    /// A collection exceeds its `ProjectGraphLimits` ceiling (`GraphDocument.checkCollectionBounds()`). Checked
    /// first. A graph with exactly the maximum edges is listed here; the destination step then refuses it.
    case bounds(ProjectGraphLimitError)
    /// A node ID repeats (the first repeat in graph order), so a port address would be ambiguous.
    case duplicateNode(NodeID)
    /// A routable node declares a port ID twice, in any direction: the first repeat, nodes in graph order and
    /// ports in node order. An observed shortcut's ports are not examined.
    case duplicatePort(PortAddress)
}
