import CoreGraphics
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
