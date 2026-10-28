import CoreGraphics

/// Stored positions are world coordinates. Only rendering and pointer locations
/// use content coordinates, translated by the scrollable world's minimum origin.
struct StudioCanvasGeometry: Equatable {
    static let cardSize = CGSize(width: 240, height: 144)
    static let controlSize: CGFloat = 44
    static let cardPadding: CGFloat = 10
    static let margin: CGFloat = 24
    static let gearWidth: CGFloat = 560
    static let controlsWidth: CGFloat = 280
    static let minimumBounds = CGRect(x: 0, y: 0, width: 840, height: 900)
    static let rowHeight: CGFloat = 168

    let worldBounds: CGRect

    init(positions: [CGPoint], retaining previousBounds: CGRect? = nil) {
        var bounds = previousBounds.map { Self.minimumBounds.union($0) } ?? Self.minimumBounds
        for position in positions {
            bounds = bounds.union(Self.cardRect(center: position).insetBy(dx: -Self.margin, dy: -Self.margin))
        }
        worldBounds = bounds
    }

    var contentSize: CGSize { worldBounds.size }

    func contentPoint(fromWorld point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - worldBounds.minX, y: point.y - worldBounds.minY)
    }

    func worldPoint(fromContent point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + worldBounds.minX, y: point.y + worldBounds.minY)
    }

    func contentCardRect(center: CGPoint) -> CGRect {
        Self.cardRect(center: contentPoint(fromWorld: center))
    }

    static func cardRect(center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - cardSize.width / 2,
            y: center.y - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height
        )
    }

    static func gearPosition(at index: Int) -> CGPoint {
        CGPoint(x: 150 + CGFloat(index % 2) * 260, y: 160 + CGFloat(index / 2) * rowHeight)
    }

    static func controlPosition(at index: Int) -> CGPoint {
        CGPoint(x: gearWidth + controlsWidth / 2, y: 160 + CGFloat(index) * rowHeight)
    }

    /// Keep the leading/top scroll origin fixed during a move. Trailing/bottom
    /// edges are unbounded so a drag can grow the canvas instead of hitting an
    /// obsolete maximum. Imported negative positions establish their own origin.
    func movedPosition(from start: CGPoint, translation: CGSize) -> CGPoint {
        CGPoint(
            x: max(start.x + translation.width, worldBounds.minX + Self.cardSize.width / 2 + Self.margin),
            y: max(start.y + translation.height, worldBounds.minY + Self.cardSize.height / 2 + Self.margin)
        )
    }

    // These anchors match the output control's center in the card's bottom row.
    func outputAnchor(center: CGPoint) -> CGPoint {
        let point = contentPoint(fromWorld: center)
        return CGPoint(
            x: point.x + Self.cardSize.width / 2 - Self.cardPadding - Self.controlSize / 2,
            y: point.y + Self.cardSize.height / 2 - Self.cardPadding - Self.controlSize / 2
        )
    }

    func inputAnchor(center: CGPoint) -> CGPoint {
        let point = contentPoint(fromWorld: center)
        return CGPoint(x: point.x - Self.cardSize.width / 2, y: outputAnchor(center: center).y)
    }
}
