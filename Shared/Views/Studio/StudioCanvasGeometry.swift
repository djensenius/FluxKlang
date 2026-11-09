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

    enum Lane { case gear, controls }

    struct Placement {
        var position: CGPoint
        var lane: Lane
    }

    let worldBounds: CGRect
    let nodeSize: CGSize
    let controlExtent: CGFloat

    init(
        positions: [CGPoint], retaining previousBounds: CGRect? = nil,
        cardSize: CGSize = Self.cardSize, controlSize: CGFloat = Self.controlSize
    ) {
        var bounds = previousBounds.map { Self.minimumBounds.union($0) } ?? Self.minimumBounds
        for position in positions {
            let paddedCard = Self.cardRect(center: position, size: cardSize).insetBy(dx: -Self.margin, dy: -Self.margin)
            bounds = bounds.union(paddedCard)
        }
        worldBounds = bounds
        nodeSize = cardSize
        controlExtent = controlSize
    }

    var contentSize: CGSize { worldBounds.size }

    func contentPoint(fromWorld point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - worldBounds.minX, y: point.y - worldBounds.minY)
    }

    func worldPoint(fromContent point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + worldBounds.minX, y: point.y + worldBounds.minY)
    }

    func contentCardRect(center: CGPoint) -> CGRect {
        Self.cardRect(center: contentPoint(fromWorld: center), size: nodeSize)
    }

    static func cardRect(center: CGPoint, size: CGSize = cardSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Separate legacy/intentional overlaps only in the rendered layout, never
    /// by mutating saved positions. Unobstructed cards retain their exact center.
    static func layoutPositions(for placements: [Placement], cardSize: CGSize = cardSize) -> [CGPoint] {
        let positions = fallbackPositions(for: placements)
        guard fastPathApplies(positions, cardSize: cardSize) else {
            return legacyLayout(positions, cardSize: cardSize)
        }
        var result: [CGPoint] = []
        result.reserveCapacity(positions.count)
        for (index, position) in positions.enumerated() {
            var candidate = position
            let rect = cardRect(center: candidate, size: cardSize)
            if result.contains(where: { rect.intersects(cardRect(center: $0, size: cardSize)) }) {
                // Reserve untouched later cards too, rather than displacing an
                // otherwise unobstructed card to make room for this one.
                let column = columnObstacles(
                    of: candidate, earlier: result, later: positions[(index + 1)...], cardSize: cardSize
                )
                while let bottom = highestOverlap(in: column, of: candidate, cardSize: cardSize) {
                    candidate.y = bottom + cardSize.height + 12
                }
            }
            result.append(candidate)
        }
        return result
    }

    /// The sorted-column search is exact only for finite, sane sizes and coordinates; everything else
    /// (including NaN) keeps the original full rescan.
    private static func fastPathApplies(_ positions: [CGPoint], cardSize: CGSize) -> Bool {
        let sizeRange: ClosedRange<CGFloat> = 1...1e6
        guard sizeRange.contains(cardSize.width), sizeRange.contains(cardSize.height) else { return false }
        let limit: CGFloat = 1e12
        return positions.allSatisfy { abs($0.x) <= limit && abs($0.y) <= limit }
    }

    /// Obstacles whose card shares the candidate's horizontal span, sorted ascending by y. The candidate's x
    /// never changes while it is displaced, so the list stays valid for every step of that card. Building it
    /// costs a pass over all other cards and a sort of the column, once per displaced card.
    private static func columnObstacles(
        of candidate: CGPoint, earlier: [CGPoint], later: ArraySlice<CGPoint>, cardSize: CGSize
    ) -> [CGPoint] {
        var column: [CGPoint] = []
        for obstacle in earlier where sharesColumn(obstacle, with: candidate, cardSize: cardSize) {
            column.append(obstacle)
        }
        for obstacle in later where sharesColumn(obstacle, with: candidate, cardSize: cardSize) {
            column.append(obstacle)
        }
        column.sort { $0.y < $1.y }
        return column
    }

    private static func sharesColumn(_ obstacle: CGPoint, with candidate: CGPoint, cardSize: CGSize) -> Bool {
        let aligned = CGPoint(x: candidate.x, y: obstacle.y)
        return cardRect(center: aligned, size: cardSize).intersects(cardRect(center: obstacle, size: cardSize))
    }

    /// The largest y among column obstacles that overlap the candidate, or nil. Binary search for the last
    /// obstacle that can reach the candidate, then walk down while one still can; the first exact hit is the largest.
    /// A call costs O(log c + k) for a column of c entries, where k is the number of entries the walk examines. The
    /// window reaches 1 point past the card height on each side, so an entry in that thin band fails the exact test
    /// and is examined in vain; k grows to c when all entries lie in the band. A step moves the candidate up by more
    /// than 11 points, so across the steps of one card an entry fails at most once above it and once below it.
    private static func highestOverlap(in column: [CGPoint], of candidate: CGPoint, cardSize: CGSize) -> CGFloat? {
        let rect = cardRect(center: candidate, size: cardSize)
        let upper = candidate.y + cardSize.height + 1
        let lower = candidate.y - cardSize.height - 1
        var low = 0
        var high = column.count
        while low < high {
            let middle = low + (high - low) / 2
            if column[middle].y <= upper { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        while index >= 0, column[index].y >= lower {
            if rect.intersects(cardRect(center: column[index], size: cardSize)) { return column[index].y }
            index -= 1
        }
        return nil
    }

    private static func legacyLayout(_ positions: [CGPoint], cardSize: CGSize) -> [CGPoint] {
        var result: [CGPoint] = []
        for (index, position) in positions.enumerated() {
            var candidate = position
            let rect = cardRect(center: candidate, size: cardSize)
            if result.contains(where: { rect.intersects(cardRect(center: $0, size: cardSize)) }) {
                let obstacles = result + positions.dropFirst(index + 1)
                while let bottom = obstacles.filter({
                    cardRect(center: candidate, size: cardSize).intersects(cardRect(center: $0, size: cardSize))
                }).map(\.y).max() {
                    candidate.y = bottom + cardSize.height + 12
                }
            }
            result.append(candidate)
        }
        return result
    }

    static func firstFreePosition(in lane: Lane, avoiding placements: [Placement]) -> CGPoint {
        // Reserve both saved/fallback and rendered centers. An insertion must
        // neither cover a displayed card nor take a displaced card's saved spot.
        let occupied = fallbackPositions(for: placements) + layoutPositions(for: placements)
        var index = 0
        while true {
            let candidate = lane == .controls ? controlPosition(at: index) : gearPosition(at: index)
            let rect = cardRect(center: candidate).insetBy(dx: -10, dy: -12)
            if !occupied.contains(where: { rect.intersects(cardRect(center: $0)) }) { return candidate }
            index += 1
        }
    }

    private static func fallbackPositions(for placements: [Placement]) -> [CGPoint] {
        var gearIndex = 0
        var controlIndex = 0
        return placements.map { placement in
            let index = placement.lane == .controls ? controlIndex : gearIndex
            if placement.lane == .controls { controlIndex += 1 } else { gearIndex += 1 }
            guard placement.position == .zero else { return placement.position }
            return placement.lane == .controls ? controlPosition(at: index) : gearPosition(at: index)
        }
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
            x: max(start.x + translation.width, worldBounds.minX + nodeSize.width / 2 + Self.margin),
            y: max(start.y + translation.height, worldBounds.minY + nodeSize.height / 2 + Self.margin)
        )
    }

    // These anchors match the output control's center in the card's bottom row.
    func outputAnchor(center: CGPoint) -> CGPoint {
        let point = contentPoint(fromWorld: center)
        return CGPoint(
            x: point.x + nodeSize.width / 2 - Self.cardPadding - controlExtent / 2,
            y: point.y + nodeSize.height / 2 - Self.cardPadding - controlExtent / 2
        )
    }

    func inputAnchor(center: CGPoint) -> CGPoint {
        let point = contentPoint(fromWorld: center)
        return CGPoint(x: point.x - nodeSize.width / 2, y: outputAnchor(center: center).y)
    }
}
