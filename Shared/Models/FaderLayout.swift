//
//  FaderLayout.swift
//  FluxKlang
//
//  The user's configurable bank of fader strips. Persisted so the mixer comes
//  back exactly as left.
//

import Foundation

/// A single configurable fader strip bound to a WING node.
struct FaderStrip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var node: WingNodeRef
    var customLabel: String?

    init(id: UUID = UUID(), node: WingNodeRef, customLabel: String? = nil) {
        self.id = id
        self.node = node
        self.customLabel = customLabel
    }
}

/// An ordered collection of fader strips.
struct FaderLayout: Codable, Sendable {
    var strips: [FaderStrip]

    init(strips: [FaderStrip] = []) {
        self.strips = strips
    }

    /// The default layout: channels 1–16 plus the main fader.
    static var standard: FaderLayout {
        var strips = (1...16).map { FaderStrip(node: .channel($0)) }
        strips.append(FaderStrip(node: .main(1)))
        return FaderLayout(strips: strips)
    }

    /// Whether a node already has a strip in this layout.
    func contains(_ node: WingNodeRef) -> Bool {
        strips.contains { $0.node == node }
    }
}
