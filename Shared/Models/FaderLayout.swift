//
//  FaderLayout.swift
//  FluxKlang
//
//  The user's configurable bank of fader strips. Persisted so the mixer comes
//  back exactly as left.
//

import Foundation

/// A single configurable fader strip bound to a WING node. A stereo strip also
/// carries a `rightNode`: the two channels are ganged (one fader drives both,
/// with a balance trim) and their mute is linked.
struct FaderStrip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var node: WingNodeRef
    /// The right channel of a stereo strip; `nil` for a mono strip.
    var rightNode: WingNodeRef?
    var customLabel: String?

    init(id: UUID = UUID(), node: WingNodeRef, rightNode: WingNodeRef? = nil, customLabel: String? = nil) {
        self.id = id
        self.node = node
        self.rightNode = rightNode
        self.customLabel = customLabel
    }

    /// Whether this strip controls a stereo (two-channel) device.
    var isStereo: Bool { rightNode != nil }
}

/// An ordered collection of fader strips.
struct FaderLayout: Codable, Sendable {
    var strips: [FaderStrip]

    init(strips: [FaderStrip] = []) {
        self.strips = strips
    }

    /// The default layout, derived from the user's gear rig: one strip per
    /// device (stereo devices become a single ganged stereo strip across their
    /// two channels), followed by the main fader.
    static var standard: FaderLayout {
        var strips = Equipment.channelAssignments().map { assignment -> FaderStrip in
            FaderStrip(
                node: .channel(assignment.leftChannel),
                rightNode: assignment.rightChannel.map(WingNodeRef.channel),
                customLabel: assignment.equipment.name
            )
        }
        strips.append(FaderStrip(node: .main(1)))
        return FaderLayout(strips: strips)
    }

    /// Whether a node already has a strip in this layout (matching either side of
    /// a stereo strip).
    func contains(_ node: WingNodeRef) -> Bool {
        strips.contains { $0.node == node || $0.rightNode == node }
    }
}
