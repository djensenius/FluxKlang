//
//  MIDISongPositionNeighbours.swift
//  FluxKlang
//
//  The two representable Song Position Pointers around a tick position, so a caller can offer them when
//  a Continue position is not a whole Song Position unit (#84).
//

/// The Song Position Pointers at or before (`floor`) and at or after (`ceiling`) a tick position.
///
/// A pointer counts whole units of `MIDIClockMath.ticksPerSongPositionUnit` ticks. Both neighbours are the
/// position itself when it is a whole unit.
struct MIDISongPositionNeighbours: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let position: UInt16
        let ticks: Int64
    }

    let floor: Point
    let ceiling: Point

    private init(floor: Point, ceiling: Point) {
        self.floor = floor
        self.ceiling = ceiling
    }

    /// Refuses a position outside `0...MIDIClockMath.maximumSongPositionTicks`.
    static func requireInRange(_ ticks: Int64) throws(MIDIInternalClockError) {
        guard (0...MIDIClockMath.maximumSongPositionTicks).contains(ticks) else {
            throw .positionOutOfRange(ticks: ticks)
        }
    }

    /// The neighbours of `ticks`, which must lie in `0...MIDIClockMath.maximumSongPositionTicks`.
    static func around(ticks: Int64) throws(MIDIInternalClockError) -> MIDISongPositionNeighbours {
        try requireInRange(ticks)
        do throws(MIDIClockError) {
            let position = try MIDIClockMath.songPosition(atOrBeforeTicks: ticks).position
            let floorTicks = try MIDIClockMath.ticks(forSongPosition: position)
            // A position below the last pointer that is not exact leaves room for `position + 1`.
            let ceilingPosition = floorTicks == ticks ? position : position + 1
            let ceilingTicks = try MIDIClockMath.ticks(forSongPosition: ceilingPosition)
            return MIDISongPositionNeighbours(floor: Point(position: position, ticks: floorTicks),
                                              ceiling: Point(position: ceilingPosition, ticks: ceilingTicks))
        } catch {
            throw .clock(error)
        }
    }
}
