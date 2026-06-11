//
//  SpeakerArray.swift
//  FluxKlang
//
//  Models a physical loudspeaker layout for surround / spatial mixing. Each
//  speaker is driven by a WING bus (the WING routes channels to buses, so a bus
//  master fader is the speaker's volume). Speakers are grouped into stereo pairs
//  (e.g. Front L/R, Rear L/R) for linked volume control.
//

import CoreGraphics
import Foundation

/// One loudspeaker in the array, driven by a WING node (a bus by default) and
/// positioned in a normalised unit square (origin top-left, listener at centre).
struct Speaker: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The WING node whose master fader is this speaker's volume.
    var node: WingNodeRef
    /// Normalised position in `0...1` on both axes.
    var position: CGPoint

    init(id: UUID = UUID(), name: String, node: WingNodeRef, position: CGPoint) {
        self.id = id
        self.name = name
        self.node = node
        self.position = position
    }
}

/// Two speakers controlled together as a stereo pair.
struct SpeakerPair: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var left: Speaker.ID
    var right: Speaker.ID

    init(id: UUID = UUID(), name: String, left: Speaker.ID, right: Speaker.ID) {
        self.id = id
        self.name = name
        self.left = left
        self.right = right
    }
}

/// A complete speaker layout: the speakers plus their stereo-pair groupings.
struct SpeakerArray: Codable, Hashable, Sendable {
    var speakers: [Speaker]
    var pairs: [SpeakerPair]

    init(speakers: [Speaker], pairs: [SpeakerPair]) {
        self.speakers = speakers
        self.pairs = pairs
    }

    /// The speaker with the given identifier, if present.
    func speaker(_ identifier: Speaker.ID) -> Speaker? {
        speakers.first { $0.id == identifier }
    }

    /// Normalised positions of every speaker, in array order.
    var positions: [CGPoint] {
        speakers.map(\.position)
    }

    /// The standard quadraphonic layout: buses 1–4 at the four corners, grouped
    /// into Front (1 & 2) and Rear (3 & 4) stereo pairs.
    static var standardQuad: SpeakerArray {
        let frontLeft = Speaker(name: "Front L", node: .bus(1), position: CGPoint(x: 0, y: 0))
        let frontRight = Speaker(name: "Front R", node: .bus(2), position: CGPoint(x: 1, y: 0))
        let rearLeft = Speaker(name: "Rear L", node: .bus(3), position: CGPoint(x: 0, y: 1))
        let rearRight = Speaker(name: "Rear R", node: .bus(4), position: CGPoint(x: 1, y: 1))
        return SpeakerArray(
            speakers: [frontLeft, frontRight, rearLeft, rearRight],
            pairs: [
                SpeakerPair(name: "Front", left: frontLeft.id, right: frontRight.id),
                SpeakerPair(name: "Rear", left: rearLeft.id, right: rearRight.id)
            ]
        )
    }
}
