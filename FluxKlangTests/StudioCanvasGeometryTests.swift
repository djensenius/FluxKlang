import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct StudioCanvasGeometryTests {
    @Test func emptyCanvasKeepsMinimumLanesAndExtent() {
        let geometry = StudioCanvasGeometry(positions: [])

        #expect(geometry.worldBounds == StudioCanvasGeometry.minimumBounds)
        #expect(geometry.contentSize == CGSize(width: 840, height: 900))
        #expect(geometry.contentPoint(fromWorld: .zero) == .zero)
    }

    @Test func addedAndFallbackNodesExpandBeyondTheOldFixedHeight() {
        let positions = (0..<24).map(StudioCanvasGeometry.gearPosition)
            + (0..<14).map(StudioCanvasGeometry.controlPosition)
        let geometry = StudioCanvasGeometry(positions: positions)

        #expect(geometry.contentSize.height > 2_000)
        for position in positions {
            expectFullCardWithMarginIsReachable(at: position, in: geometry)
        }
        #expect(StudioCanvasGeometry.rowHeight > StudioCanvasGeometry.cardSize.height)
    }

    @Test func importedFarRightAndBottomPositionsAreNotClampedToOldExtent() {
        let positions = [CGPoint(x: 5_000, y: 120), CGPoint(x: 120, y: 7_000)]
        let geometry = StudioCanvasGeometry(positions: positions)

        for position in positions {
            expectFullCardWithMarginIsReachable(at: position, in: geometry)
        }
        #expect(geometry.worldBounds.maxX == 5_144)
        #expect(geometry.worldBounds.maxY == 7_096)
    }

    @Test func negativeWorldPositionsHaveAnExplicitReversibleContentOrigin() {
        let position = CGPoint(x: -600, y: -900)
        let geometry = StudioCanvasGeometry(positions: [position])
        let contentPoint = geometry.contentPoint(fromWorld: position)

        #expect(geometry.worldBounds.origin == CGPoint(x: -744, y: -996))
        #expect(contentPoint == CGPoint(x: 144, y: 96))
        #expect(geometry.worldPoint(fromContent: contentPoint) == position)
        expectFullCardWithMarginIsReachable(at: position, in: geometry)
    }

    @Test func cardsWiresAndDropHitTestsUseTheSameTransform() {
        let position = CGPoint(x: -600, y: -900)
        let geometry = StudioCanvasGeometry(positions: [position])
        let card = geometry.contentCardRect(center: position)
        let output = geometry.outputAnchor(center: position)
        let input = geometry.inputAnchor(center: position)
        let inset = StudioCanvasGeometry.cardPadding + StudioCanvasGeometry.controlSize / 2

        #expect(card.contains(geometry.contentPoint(fromWorld: position)))
        #expect(output == CGPoint(x: card.maxX - inset, y: card.maxY - inset))
        #expect(input == CGPoint(x: card.minX, y: output.y))
        #expect(geometry.worldPoint(fromContent: output) == CGPoint(x: position.x + 88, y: position.y + 40))
    }

    @Test func deletingOrCancellingAFarNodeDoesNotShrinkMountedBounds() {
        let positions = [CGPoint(x: -600, y: -900), CGPoint(x: 5_000, y: 7_000)]
        let expanded = StudioCanvasGeometry(positions: positions)
        let afterRemoval = StudioCanvasGeometry(positions: [], retaining: expanded.worldBounds)

        #expect(afterRemoval == expanded)
        #expect(afterRemoval.contentPoint(fromWorld: .zero) == expanded.contentPoint(fromWorld: .zero))
    }

    @Test func moveCanGrowTrailingExtentWithoutMovingTheStartingOrigin() {
        let start = CGPoint(x: -600, y: -900)
        let starting = StudioCanvasGeometry(positions: [start])
        let final = starting.movedPosition(from: start, translation: CGSize(width: 8_000, height: 9_000))
        let duringDrag = StudioCanvasGeometry(positions: [final], retaining: starting.worldBounds)
        let afterCommit = StudioCanvasGeometry(positions: [final], retaining: duringDrag.worldBounds)

        #expect(final == CGPoint(x: 7_400, y: 8_100))
        #expect(duringDrag.worldBounds.origin == starting.worldBounds.origin)
        #expect(afterCommit == duringDrag)
        expectFullCardWithMarginIsReachable(at: final, in: duringDrag)
    }

    @Test func moveClampsOnlyAtTheExistingLeadingAndTopWorldEdges() {
        let start = CGPoint(x: -600, y: -900)
        let geometry = StudioCanvasGeometry(positions: [start])
        let final = geometry.movedPosition(from: start, translation: CGSize(width: -5_000, height: -5_000))

        #expect(final == start)
        #expect(final.x < 0 && final.y < 0)
        expectFullCardWithMarginIsReachable(at: final, in: geometry)
    }

    @Test func legacySavedRowsAndEffectColumnsSeparateWithoutChangingSavedPositions() {
        let saved = (0..<8).map { CGPoint(x: 700, y: 120 + CGFloat($0) * 100) }
            + (0..<6).map { CGPoint(x: 150, y: 150 + CGFloat($0) * 110) }
            + (0..<4).map { CGPoint(x: 360 + CGFloat($0) * 190, y: 160) }
        let placements = saved.map { StudioCanvasGeometry.Placement(position: $0, lane: .gear) }
        let rendered = StudioCanvasGeometry.layoutPositions(for: placements)

        #expect(placements.map(\.position) == saved)
        #expect(rendered != saved)
        #expect(rendered == StudioCanvasGeometry.layoutPositions(for: placements))
        expectNoOverlap(rendered)
        let geometry = StudioCanvasGeometry(positions: rendered)
        for position in rendered { expectFullCardWithMarginIsReachable(at: position, in: geometry) }
    }

    @Test func unobstructedCustomPositionsArePreservedIncludingNegativeAndFutureCards() {
        let saved = [CGPoint(x: -200, y: -300), CGPoint(x: -200, y: -200), CGPoint(x: -200, y: 20)]
        let placements = saved.map { StudioCanvasGeometry.Placement(position: $0, lane: .gear) }
        let rendered = StudioCanvasGeometry.layoutPositions(for: placements)

        #expect(rendered[0] == saved[0])
        #expect(rendered[2] == saved[2])
        #expect(rendered[1] != saved[1])
        expectNoOverlap(rendered)
    }

    @Test func deleteMiddleThenAddUsesFirstFreeGearAndControlSlots() {
        for lane in [StudioCanvasGeometry.Lane.gear, .controls] {
            let position = lane == .controls ? StudioCanvasGeometry.controlPosition : StudioCanvasGeometry.gearPosition
            let occupied = [0, 2, 3].map {
                StudioCanvasGeometry.Placement(position: position($0), lane: lane)
            }
            let added = StudioCanvasGeometry.firstFreePosition(in: lane, avoiding: occupied)

            #expect(added == position(1))
            expectNoOverlap(occupied.map(\.position) + [added])
        }
    }

    @Test func insertionReservesMovedCardsBothLanesFallbackAndSeparatedPositions() {
        let placements = [
            StudioCanvasGeometry.Placement(position: CGPoint(x: 150, y: 160), lane: .controls),
            StudioCanvasGeometry.Placement(position: CGPoint(x: 150, y: 160), lane: .gear),
            StudioCanvasGeometry.Placement(position: .zero, lane: .controls)
        ]
        let rendered = StudioCanvasGeometry.layoutPositions(for: placements)
        let added = StudioCanvasGeometry.firstFreePosition(in: .gear, avoiding: placements)

        #expect(added != StudioCanvasGeometry.gearPosition(at: 0))
        #expect(!StudioCanvasGeometry.cardRect(center: added).intersects(
            StudioCanvasGeometry.cardRect(center: placements[0].position)
        ))
        expectNoOverlap(rendered + [added])
    }

    @Test func accessibilityCardSizeUsesMatchingSeparationBoundsAnchorsAndHitRects() {
        let size = CGSize(width: 720, height: 432)
        let placements = (0..<10).map {
            StudioCanvasGeometry.Placement(position: StudioCanvasGeometry.gearPosition(at: $0), lane: .gear)
        }
        let positions = StudioCanvasGeometry.layoutPositions(for: placements, cardSize: size)
        let geometry = StudioCanvasGeometry(positions: positions, cardSize: size, controlSize: 132)

        expectNoOverlap(positions, size: size)
        for position in positions {
            let card = geometry.contentCardRect(center: position)
            let output = geometry.outputAnchor(center: position)
            #expect(card.size == size)
            #expect(card.contains(output))
            #expect(output == CGPoint(x: card.maxX - 76, y: card.maxY - 76))
            #expect(geometry.worldBounds.contains(StudioCanvasGeometry.cardRect(center: position, size: size)))
        }
    }

    private func expectNoOverlap(_ positions: [CGPoint], size: CGSize = StudioCanvasGeometry.cardSize) {
        for index in positions.indices {
            for other in positions.dropFirst(index + 1) {
                #expect(!StudioCanvasGeometry.cardRect(center: positions[index], size: size).intersects(
                    StudioCanvasGeometry.cardRect(center: other, size: size)
                ))
            }
        }
    }

    private func expectFullCardWithMarginIsReachable(at point: CGPoint, in geometry: StudioCanvasGeometry) {
        let paddedCard = StudioCanvasGeometry.cardRect(center: point).insetBy(
            dx: -StudioCanvasGeometry.margin,
            dy: -StudioCanvasGeometry.margin
        )
        #expect(geometry.worldBounds.contains(paddedCard))
        let card = geometry.contentCardRect(center: point)
        #expect(card.minX >= StudioCanvasGeometry.margin)
        #expect(card.minY >= StudioCanvasGeometry.margin)
        #expect(card.maxX + StudioCanvasGeometry.margin <= geometry.contentSize.width)
        #expect(card.maxY + StudioCanvasGeometry.margin <= geometry.contentSize.height)
    }
}

extension StudioCanvasGeometryTests {
    @Test func layoutMatchesLegacyReferenceOnGeneratedPlacements() {
        var mismatches: [String] = []
        var cases = 0
        let plans = [(0, 6), (1, 6), (2, 6), (3, 6), (5, 6), (8, 6), (64, 1), (256, 1)]
        for (count, seeds) in plans {
            for seed in 1...seeds {
                for shape in 0..<SCG1Cases.shapeCount {
                    cases += 1
                    if let mismatch = SCG1Cases.mismatch(count: count, seed: UInt64(seed), shape: shape, index: cases) {
                        mismatches.append(mismatch)
                    }
                }
            }
        }
        let edges = SCG1Cases.windowEdges()
        mismatches += edges.mismatches
        // (6 counts x 6 seeds + 2 counts at seed 1) x 10 shapes, plus the 48 window-edge fixtures
        let total = cases + edges.count
        let expected: Int = 428
        #expect(total == expected)
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }

    @Test func layoutMatchesLegacyReferenceForGuardedInputs() {
        let standard = StudioCanvasGeometry.cardSize
        let stacked = Array(repeating: CGPoint(x: 300, y: 300), count: 5)
        let origin = CGPoint(x: 0, y: 0)
        let farY = CGFloat(1e12)
        let sizeCases: [CGSize] = [
            CGSize(width: 0, height: 144), CGSize(width: 240, height: 0), CGSize(width: 1_000_001, height: 144),
            CGSize(width: 240, height: 1_000_001), CGSize(width: CGFloat.nan, height: 144),
            CGSize(width: 1, height: 1), CGSize(width: 1_000_000, height: 144), CGSize(width: 1e7, height: 1e7),
            CGSize(width: 1e300, height: 144), CGSize(width: 0.4, height: 0.4), CGSize(width: 240, height: 0.5)
        ]
        var mismatches: [String] = []
        var generator = SCG1SplitMix(state: 99)
        let base = SCG1Cases.dense(&generator, 8) + SCG1Cases.cascade(&generator, 8)
        let ascending = [0, 10, 500, 20, 30, 40].map { CGPoint(x: 0, y: CGFloat($0)) }
        for (index, size) in sizeCases.enumerated() {
            for (kind, positions) in [stacked, base, ascending].enumerated() {
                var rng = SCG1SplitMix(state: UInt64(index))
                let placements = SCG1Cases.placements(positions, rng: &rng)
                if let mismatch = SCG1Cases.compare(placements, cardSize: size, label: "size \(index) \(kind)") {
                    mismatches.append(mismatch)
                }
            }
        }
        let positionCases: [[CGPoint]] = [
            [origin, CGPoint(x: CGFloat.nan, y: 0), origin, origin],
            [origin, CGPoint(x: 0, y: CGFloat.infinity), origin, origin],
            [origin, CGPoint(x: -CGFloat.infinity, y: 0), origin, origin],
            Array(repeating: CGPoint(x: 0, y: farY + 1), count: 5),
            Array(repeating: CGPoint(x: farY + 1, y: 0), count: 5),
            Array(repeating: CGPoint(x: 0, y: -farY - 1), count: 5),
            Array(repeating: CGPoint(x: 0, y: farY), count: 5),
            Array(repeating: CGPoint(x: -farY, y: -farY), count: 5)
        ]
        var withOdd: [[CGPoint]] = []
        let odd = [CGPoint(x: CGFloat.nan, y: 5), CGPoint(x: 5, y: CGFloat.infinity), CGPoint(x: 0, y: farY + 1)]
        withOdd += odd.map { point in
            var positions = base
            positions.insert(point, at: 3)
            return positions
        }
        let huge = CGFloat(1e17)
        withOdd += [1e15, 1e16, 1e17].map { Array(repeating: CGPoint(x: 0, y: CGFloat($0)), count: 6) }
        withOdd.append(base.map { CGPoint(x: $0.x, y: $0.y + huge) })
        withOdd.append(ascending.map { CGPoint(x: $0.x, y: $0.y + huge) })
        for (index, positions) in (positionCases + withOdd).enumerated() {
            var rng = SCG1SplitMix(state: UInt64(index))
            let placements = SCG1Cases.placements(positions, rng: &rng)
            if let mismatch = SCG1Cases.compare(placements, cardSize: standard, label: "position \(index)") {
                mismatches.append(mismatch)
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test(.enabled(if: SCG1Source.directory() != nil, "the sources are not next to the tests"))
    func layoutFastPathSourceHasNoConcatenationFilterOrMaxTokens() throws {
        let text = try SCG1Source.text()
        let start = try #require(text.range(of: "static func layoutPositions"))
        let end = try #require(text.range(of: "private static func legacyLayout"))
        let startsBeforeEnd = start.lowerBound < end.lowerBound
        #expect(startsBeforeEnd)
        let fastPath = String(text[start.lowerBound..<end.lowerBound])
        let concatenates = fastPath.contains("result + positions")
        let filters = fastPath.contains(".filter")
        let maximizes = fastPath.contains(".max()")
        #expect(!concatenates)
        #expect(!filters)
        #expect(!maximizes)
    }
}

private enum SCG1Source {
    static func directory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Views/Studio", "../../Sources/FluxKlang/Shared/Views/Studio"]
        for candidate in candidates {
            let url = here.appendingPathComponent(candidate).standardized
            let marker = url.appendingPathComponent("StudioCanvasGeometry.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return url }
        }
        return nil
    }

    static func text() throws -> String {
        let url = try #require(directory(), "the sources are not next to the tests")
        return try String(contentsOf: url.appendingPathComponent("StudioCanvasGeometry.swift"), encoding: .utf8)
    }
}

private struct SCG1SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private struct SCG1Case {
    var placements: [StudioCanvasGeometry.Placement]
    var cardSize: CGSize
}

private enum SCG1Cases {
    typealias Shape = @Sendable (inout SCG1SplitMix, Int) -> [CGPoint]

    static let shapeCount = 10
    static let cardSizes = [
        CGSize(width: 240, height: 144), CGSize(width: 720, height: 432),
        CGSize(width: 1, height: 1), CGSize(width: 300, height: 77.5)
    ]
    static let shapes: [Shape] = [stacked, grid, dense, negative, mixed, column, edgeTouch, columnEdge]

    static func mismatch(count: Int, seed: UInt64, shape: Int, index: Int) -> String? {
        let made = make(count: count, seed: seed, shape: shape, index: index)
        return compare(made.placements, cardSize: made.cardSize, label: "n\(count) seed\(seed) shape\(shape)")
    }

    static func make(count: Int, seed: UInt64, shape: Int, index: Int) -> SCG1Case {
        var rng = SCG1SplitMix(state: seed &* 7_919 &+ UInt64(shape))
        let size = cardSizes[index % cardSizes.count]
        let positions: [CGPoint]
        var cardSize = StudioCanvasGeometry.cardSize
        if shape < shapes.count {
            positions = shapes[shape](&rng, count)
        } else if shape == shapes.count {
            positions = cascade(&rng, count)
            cardSize = size
        } else {
            positions = shapes[index % shapes.count](&rng, count)
            cardSize = size
        }
        return SCG1Case(placements: placements(positions, rng: &rng), cardSize: cardSize)
    }

    static func placements(_ positions: [CGPoint], rng: inout SCG1SplitMix) -> [StudioCanvasGeometry.Placement] {
        var placed: [StudioCanvasGeometry.Placement] = []
        for position in positions {
            let lane: StudioCanvasGeometry.Lane = rng.below(2) == 0 ? .gear : .controls
            placed.append(StudioCanvasGeometry.Placement(position: position, lane: lane))
        }
        return placed
    }

    static func compare(_ placements: [StudioCanvasGeometry.Placement], cardSize: CGSize, label: String) -> String? {
        let actual = StudioCanvasGeometry.layoutPositions(for: placements, cardSize: cardSize)
        let expected = legacyLayoutReference(placements, cardSize: cardSize)
        let actualBits = bits(actual)
        let expectedBits = bits(expected)
        let sameCount = actual.count == placements.count
        if actualBits == expectedBits, sameCount { return nil }
        return label
    }

    static func bits(_ points: [CGPoint]) -> [UInt64] {
        points.flatMap { [$0.x.native.bitPattern, $0.y.native.bitPattern] }
    }

    static func stacked(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        Array(repeating: CGPoint(x: 300, y: 300), count: count)
    }

    static func grid(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        (0..<count).map { _ in CGPoint(x: CGFloat(10 * rng.below(13)), y: CGFloat(10 * rng.below(13))) }
    }

    static func dense(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        (0..<count).map { _ in CGPoint(x: CGFloat(rng.below(400)), y: CGFloat(rng.below(400))) }
    }

    static func negative(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        (0..<count).map { _ in CGPoint(x: CGFloat(-1 - rng.below(600)), y: CGFloat(-1 - rng.below(600))) }
    }

    static func mixed(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        var found: [CGPoint] = []
        for _ in 0..<count {
            let kind = rng.below(3)
            if kind == 0 {
                found.append(.zero)
            } else if kind == 1, !found.isEmpty {
                found.append(found[rng.below(found.count)])
            } else {
                found.append(CGPoint(x: CGFloat(rng.below(400)), y: CGFloat(rng.below(400))))
            }
        }
        return found
    }

    static func column(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        (0..<count).map { index -> CGPoint in
            if index.isMultiple(of: 2) { return CGPoint(x: 200, y: 200) }
            return CGPoint(x: CGFloat(rng.below(400)), y: CGFloat(rng.below(400)))
        }
    }

    static func edgeTouch(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        let rows: [CGFloat] = [0, 144, 156, 288, 300, 312]
        return (0..<count).map { _ in CGPoint(x: CGFloat(240 * rng.below(3)), y: rows[rng.below(rows.count)]) }
    }

    static func cascade(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        (0..<count).map { _ in CGPoint(x: CGFloat(120 * rng.below(4)), y: CGFloat(12 * rng.below(51))) }
    }

    /// Anchor cards at x 300 alternate with cards a hair inside or outside one card width, on both sides.
    static func columnEdge(_ rng: inout SCG1SplitMix, _ count: Int) -> [CGPoint] {
        let offsets: [CGFloat] = [239, 239.5, 240, 240.5, -239, -239.5, -240, -240.5]
        return (0..<count).map { index -> CGPoint in
            let shift = index.isMultiple(of: 2) ? 0 : offsets[(index / 2) % offsets.count]
            return CGPoint(x: 300 + shift, y: 300 + CGFloat(60 * rng.below(3)))
        }
    }

    /// A card whose only neighbour sits h-1.5 ... h+1 above or below it (alone, or with a stacked twin first).
    static func windowEdges() -> (count: Int, mismatches: [String]) {
        var found: [String] = []
        var count = 0
        let stacked = CGPoint(x: 300, y: 300)
        for size in [StudioCanvasGeometry.cardSize, CGSize(width: 300, height: 77.5)] {
            for gap in [-1.5, -1, -0.5, 0, 0.5, 1].map({ size.height + CGFloat($0) }) {
                for sign in [CGFloat(1), -1] {
                    let apart = CGPoint(x: 300, y: 300 + sign * gap)
                    for positions in [[stacked, apart], [stacked, stacked, apart]] {
                        var rng = SCG1SplitMix(state: 1)
                        let placed = placements(positions, rng: &rng)
                        count += 1
                        if let issue = compare(placed, cardSize: size, label: "window \(size.height) \(sign * gap)") {
                            found.append(issue)
                        }
                    }
                }
            }
        }
        return (count, found)
    }

    /// Copy of origin/main 4f7e6476 `layoutPositions`; renames: `cardRect` is `StudioCanvasGeometry.cardRect`.
    static func legacyLayoutReference(
        _ placements: [StudioCanvasGeometry.Placement], cardSize: CGSize
    ) -> [CGPoint] {
        let positions = referenceFallbackPositions(for: placements)
        var result: [CGPoint] = []
        for (index, position) in positions.enumerated() {
            var candidate = position
            let rect = StudioCanvasGeometry.cardRect(center: candidate, size: cardSize)
            if result.contains(where: { rect.intersects(StudioCanvasGeometry.cardRect(center: $0, size: cardSize)) }) {
                let obstacles = result + positions.dropFirst(index + 1)
                while let bottom = obstacles.filter({
                    StudioCanvasGeometry.cardRect(center: candidate, size: cardSize)
                        .intersects(StudioCanvasGeometry.cardRect(center: $0, size: cardSize))
                }).map(\.y).max() {
                    candidate.y = bottom + cardSize.height + 12
                }
            }
            result.append(candidate)
        }
        return result
    }

    /// Copy of origin/main 4f7e6476 `fallbackPositions`.
    static func referenceFallbackPositions(for placements: [StudioCanvasGeometry.Placement]) -> [CGPoint] {
        var gearIndex = 0
        var controlIndex = 0
        return placements.map { placement in
            let index = placement.lane == .controls ? controlIndex : gearIndex
            if placement.lane == .controls { controlIndex += 1 } else { gearIndex += 1 }
            guard placement.position == .zero else { return placement.position }
            return placement.lane == .controls
                ? StudioCanvasGeometry.controlPosition(at: index)
                : StudioCanvasGeometry.gearPosition(at: index)
        }
    }
}
