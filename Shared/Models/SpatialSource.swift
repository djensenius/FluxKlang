//
//  SpatialSource.swift
//  FluxKlang
//
//  An instrument placed in the spatial field. A source is either mono (one WING
//  channel) or stereo (two arbitrary WING channels — which need not be an
//  adjacent stereo-linked pair). A stereo source has a width that spreads its
//  left and right channels apart around the source's position.
//

import CoreGraphics
import Foundation

/// Whether a spatial source occupies one channel or two.
enum SpatialSourceMode: String, Codable, Hashable, Sendable, CaseIterable {
    case mono
    case stereo
}

/// An instrument positioned in the spatial field, mapped to one or two WING
/// channels whose bus sends are driven by the panner.
struct SpatialSource: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var mode: SpatialSourceMode
    /// The mono channel, or the left channel of a stereo source.
    var left: WingNodeRef
    /// The right channel of a stereo source. Ignored when `mode` is `.mono`.
    var right: WingNodeRef?
    /// Normalised position in `0...1` on both axes.
    var position: CGPoint
    /// Stereo spread in `0...1`; widens the gap between the left/right channels.
    var width: Double

    init(
        id: UUID = UUID(),
        name: String,
        mode: SpatialSourceMode = .mono,
        left: WingNodeRef,
        right: WingNodeRef? = nil,
        position: CGPoint = CGPoint(x: 0.5, y: 0.5),
        width: Double = 0.5
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.left = left
        self.right = right
        self.position = position
        self.width = width
    }

    /// Whether this source is stereo and has a valid right channel.
    var isStereo: Bool {
        mode == .stereo && right != nil
    }

    /// The effective placement of each WING channel that makes up this source. A
    /// mono source yields one entry; a stereo source yields its left and right
    /// channels spread horizontally around `position` by `width`.
    func channelPlacements() -> [(channel: WingNodeRef, point: CGPoint)] {
        guard isStereo, let right else {
            return [(left, position)]
        }
        let offset = width * 0.25
        let leftX = min(max(Double(position.x) - offset, 0), 1)
        let rightX = min(max(Double(position.x) + offset, 0), 1)
        return [
            (left, CGPoint(x: leftX, y: Double(position.y))),
            (right, CGPoint(x: rightX, y: Double(position.y)))
        ]
    }
}
