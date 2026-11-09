//
//  WiringImpactGesture.swift
//  FluxKlang
//
//  The one prospective wiring gesture whose impact is previewed (#101 WPV1). Each case except `.none` names the
//  existing composer that turns it into a new draft; nothing here edits anything.
//

/// One prospective gesture. `.none` is the empty gesture (nothing hovered): it names no composer and yields an empty
/// impact, but `WiringImpact.make` still checks the draft first, so a stale draft is refused with `preview` and a draft
/// graph whose validation stops before checking wires with `baselineUncheckable`.
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
