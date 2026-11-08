//
//  WiringImpactGesture.swift
//  FluxKlang
//
//  The one prospective wiring gesture whose impact is previewed (#101 WPV1). Each case names the existing composer
//  that turns it into a new draft; nothing here edits anything.
//

/// One prospective gesture. `.none` is the empty gesture (nothing hovered): a result, never a refusal.
enum WiringImpactGesture: Equatable, Sendable {
    case none
    case connect(WiringConnectRequest)
    case removeEdge(EdgeID)
    case restoreEdge(EdgeID)
    // swiftlint:disable:next identifier_name
    case moveNode(NodeID, x: Double, y: Double)
    case addNode(GraphNode)
    case removeNode(NodeID)
}
