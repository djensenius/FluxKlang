import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIInternalClockTests {
    static func point(_ position: UInt16, _ ticks: Int64) -> MIDISongPositionNeighbours.Point {
        MIDISongPositionNeighbours.Point(position: position, ticks: ticks)
    }

    // MARK: - Event order

    @Test
    func theFrameOrdersEventsBeforeTheMessageRankAndThePulseIndex() {
        let lateClock = Self.clock(11, 0)
        let earlyStop = Self.event(10, .stop)
        #expect(MIDIInternalClockEvent.precedes(earlyStop, lateClock))
        #expect(!MIDIInternalClockEvent.precedes(lateClock, earlyStop))
        let earlyClock = Self.clock(10, 9)
        let lateStop = Self.event(11, .stop)
        #expect(MIDIInternalClockEvent.precedes(earlyClock, lateStop))
        #expect(!MIDIInternalClockEvent.precedes(lateStop, earlyClock))
        let negative = Self.clock(-5, 7)
        #expect(MIDIInternalClockEvent.precedes(negative, Self.clock(-4, 0)))
        #expect(!MIDIInternalClockEvent.precedes(Self.clock(-4, 0), negative))
    }

    @Test
    func atOneFrameAStopPrecedesTheSongPositionWhichPrecedesTheStartWhichPrecedesTheClock() {
        let ascending = [Self.event(100, .stop), Self.event(100, .songPosition(5)), Self.event(100, .start),
                         Self.clock(100, 0)]
        for low in ascending.indices {
            for high in ascending.indices where low < high {
                #expect(MIDIInternalClockEvent.precedes(ascending[low], ascending[high]), "\(low) before \(high)")
                #expect(!MIDIInternalClockEvent.precedes(ascending[high], ascending[low]), "\(high) before \(low)")
            }
        }
        let continued = Self.event(100, .continue)
        #expect(MIDIInternalClockEvent.precedes(ascending[1], continued))
        #expect(MIDIInternalClockEvent.precedes(ascending[0], continued))
        #expect(MIDIInternalClockEvent.precedes(continued, ascending[3]))
        #expect(!MIDIInternalClockEvent.precedes(ascending[3], continued))
    }

    @Test
    func aStartAndAContinueAtOneFrameHaveTheSameRankAndNeitherPrecedes() {
        let start = Self.event(100, .start)
        let continued = Self.event(100, .continue)
        #expect(!MIDIInternalClockEvent.precedes(start, continued))
        #expect(!MIDIInternalClockEvent.precedes(continued, start))
        #expect(!MIDIInternalClockEvent.precedes(start, start))
    }

    @Test
    func clocksAtOneFrameAreOrderedByPulseIndexAndAMissingIndexCountsAsZero() {
        #expect(MIDIInternalClockEvent.precedes(Self.clock(10, 1), Self.clock(10, 2)))
        #expect(!MIDIInternalClockEvent.precedes(Self.clock(10, 2), Self.clock(10, 1)))
        #expect(!MIDIInternalClockEvent.precedes(Self.clock(10, 2), Self.clock(10, 2)))
        let unnumbered = Self.event(10, .clock)
        #expect(!MIDIInternalClockEvent.precedes(unnumbered, Self.clock(10, 0)))
        #expect(!MIDIInternalClockEvent.precedes(Self.clock(10, 0), unnumbered))
        #expect(MIDIInternalClockEvent.precedes(unnumbered, Self.clock(10, 1)))
        #expect(!MIDIInternalClockEvent.precedes(Self.clock(10, 1), unnumbered))
        #expect(MIDIInternalClockEvent.precedes(Self.clock(10, -1), unnumbered))
    }

    @Test
    func sortingAShuffledSetOfEventsYieldsTheDocumentedTotalOrder() {
        let ordered = [Self.event(0, .start), Self.clock(0, 0), Self.event(1_000, .stop),
                       Self.event(1_000, .songPosition(3)), Self.event(1_000, .continue), Self.clock(1_000, 1),
                       Self.clock(1_000, 2), Self.clock(2_000, 2)]
        let rotated = Array(ordered.dropFirst(3)) + Array(ordered.prefix(3))
        for shuffled in [Array(ordered.reversed()), rotated] {
            #expect(shuffled.sorted(by: MIDIInternalClockEvent.precedes) == ordered)
        }
    }

    @Test
    func anEventKeepsItsFieldsWhenItIsStamped() {
        let event = Self.clock(1_000, 1)
        let stamped = event.stamped(HostStamp(ticks: 42))
        #expect(stamped.frame == 1_000)
        #expect(stamped.message == .clock)
        #expect(stamped.pulseIndex == 1)
        #expect(stamped.hostStamp == HostStamp(ticks: 42))
        #expect(event.hostStamp == nil)
        #expect(Self.event(5, .stop).pulseIndex == nil)
    }

    // MARK: - Song Position neighbours

    @Test
    func theNeighboursOfAWholeSongPositionUnitAreThatUnitOnBothSides() throws {
        let whole: [(UInt16, Int64)] = [(0, 0), (1, 3_840), (16_383, 62_910_720)]
        for (position, ticks) in whole {
            let neighbours = try MIDISongPositionNeighbours.around(ticks: ticks)
            #expect(neighbours.floor == Self.point(position, ticks))
            #expect(neighbours.ceiling == Self.point(position, ticks))
        }
    }

    @Test
    func theNeighboursInsideASongPositionUnitAreTheSurroundingUnits() throws {
        let inside = try MIDISongPositionNeighbours.around(ticks: 5_000)
        #expect(inside.floor == Self.point(1, 3_840))
        #expect(inside.ceiling == Self.point(2, 7_680))
        let aboveZero = try MIDISongPositionNeighbours.around(ticks: 1)
        #expect(aboveZero.floor == Self.point(0, 0))
        #expect(aboveZero.ceiling == Self.point(1, 3_840))
        let belowUnit = try MIDISongPositionNeighbours.around(ticks: 3_839)
        #expect(belowUnit.floor == Self.point(0, 0))
        #expect(belowUnit.ceiling == Self.point(1, 3_840))
        let belowLast = try MIDISongPositionNeighbours.around(ticks: 62_910_719)
        #expect(belowLast.floor == Self.point(16_382, 62_906_880))
        #expect(belowLast.ceiling == Self.point(16_383, 62_910_720))
    }

    @Test
    func theNeighboursRefusePositionsOutsideTheSongPositionRange() throws {
        for ticks in [Int64(-1), 62_910_721, 62_914_559, Int64.max, Int64.min] {
            #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: ticks)) {
                try MIDISongPositionNeighbours.around(ticks: ticks)
            }
        }
        // `MIDIClockMath` alone accepts the first sixteenth past the last pointer; the neighbours do not.
        #expect(try MIDIClockMath.songPosition(atOrBeforeTicks: 62_914_559).position == 16_383)
    }

    @Test
    func theSongPositionRangeIsZeroThroughTheLastPointersTickAndNothingElse() throws {
        try MIDISongPositionNeighbours.requireInRange(0)
        try MIDISongPositionNeighbours.requireInRange(62_910_720)
        for ticks in [Int64(-1), 62_910_721] {
            #expect(throws: MIDIInternalClockError.positionOutOfRange(ticks: ticks)) {
                try MIDISongPositionNeighbours.requireInRange(ticks)
            }
        }
    }
}
