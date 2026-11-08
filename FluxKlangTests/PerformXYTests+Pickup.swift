//
//  PerformXYTests+Pickup.swift
//  FluxKlangTests
//
//  The one pickup decision both axes share: a waiting pad holds a distant pointer, an entry and an adjustment and
//  returns no pad, a sequence of distant pointers each holds at the starting position, a caught pointer engages,
//  and the two explicit actions, taking over and a host move.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformXYTests {
    @Test
    func aWaitingPadReturnsAHoldForAnEntryAnAdjustmentAndADistantPointer() throws {
        let pad = try Self.pad(0, 0, .waiting, radius: 5)
        Self.expectHold(
            try pad.entering(x: 5, y: nil), requested: Self.point(5, 0), current: Self.point(0, 0)
        )
        Self.expectHold(
            try pad.entering(x: 500, y: -500), requested: Self.point(100, -50), current: Self.point(0, 0)
        )
        Self.expectHold(
            try pad.adjusting(.x, by: 150), requested: Self.point(100, 0), current: Self.point(0, 0)
        )
        Self.expectHold(
            try pad.adjusting(.y, by: -2), requested: Self.point(0, -2), current: Self.point(0, 0)
        )
        Self.expectHold(
            pad.pointer(Self.point(40, 40)), requested: Self.point(40, 40), current: Self.point(0, 0)
        )
    }

    @Test
    func aSequenceOfDistantPointersEachReturnsAHoldAtTheStartingPosition() throws {
        let pad = try Self.pad(10, 10, .waiting, radius: 2)
        let pointers = [Self.point(50, 50), Self.point(-20, 0), Self.point(13, 10), Self.point(10, 13)]
        var heldCount = 0
        for pointer in pointers {
            let hold = try #require(Self.hold(of: pad.pointer(pointer)))
            #expect(hold.current == Self.point(10, 10))
            heldCount += 1
        }
        #expect(heldCount == 4)
    }

    @Test
    func takingOverEngagesWithoutMovingAndKeepsAnEngagedPadEngaged() throws {
        let waiting = try Self.pad(30, -20, .waiting, radius: 7)
        #expect(waiting.takingOver() == (try Self.pad(30, -20, .engaged, radius: 7)))
        let engaged = try Self.pad(30, -20, .engaged, radius: 7)
        #expect(engaged.takingOver() == engaged)
        Self.expectMove(waiting.takingOver().pointer(Self.point(90, 40)), to: Self.point(90, 40), nil, nil)
    }

    @Test
    func hostMovedClampsThePositionAndWaits() throws {
        let engaged = try Self.pad(0, 0, .engaged, radius: 3)
        #expect(engaged.hostMoved(to: Self.point(500, -500)) == (try Self.pad(100, -50, .waiting, radius: 3)))
        #expect(engaged.hostMoved(to: Self.point(10, 20)) == (try Self.pad(10, 20, .waiting, radius: 3)))
        #expect(engaged.hostMoved(to: Self.point(-100, 50)) == (try Self.pad(-100, 50, .waiting, radius: 3)))
        let moved = engaged.hostMoved(to: Self.point(10, 20))
        Self.expectHold(moved.pointer(Self.point(40, 40)), requested: Self.point(40, 40), current: Self.point(10, 20))
    }

    @Test
    func pointerTakeOverAndHostMoveKeepTheRangesAndTheCaptureRadius() throws {
        let pad = try Self.pad(1, 2, .waiting, radius: 9)
        let moved = try #require(Self.move(of: pad.pointer(Self.point(2, 3))))
        let taken = pad.takingOver()
        let host = pad.hostMoved(to: Self.point(4, 5))
        for result in [moved.pad, taken, host] {
            #expect(result.captureRadius == 9)
            #expect(result.xRange == pad.xRange)
            #expect(result.yRange == pad.yRange)
        }
        #expect(pad.xRange.lower == -100)
        #expect(pad.yRange.upper == 50)
    }
}
