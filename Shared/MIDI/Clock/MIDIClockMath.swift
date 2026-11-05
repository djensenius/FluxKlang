//
//  MIDIClockMath.swift
//  FluxKlang
//
//  Exact MIDI 1 timing-clock arithmetic on the fixed musical tick grid:
//  24 pulses per quarter (640 ticks each) and 14-bit Song Position Pointer
//  units of six pulses (3,840 ticks).
//

/// A tick position split into a Song Position Pointer and the pulses and ticks after it.
struct MIDISongPositionSplit: Equatable, Sendable {
    let position: UInt16
    let remainderPulses: Int64
    let remainderTicks: Int64
}

enum MIDIClockMath {
    static let pulsesPerQuarter: Int64 = 24
    static let ticksPerPulse: Int64 = MusicalTime.ticksPerQuarter / pulsesPerQuarter
    static let pulsesPerSongPositionUnit: Int64 = 6
    static let ticksPerSongPositionUnit: Int64 = ticksPerPulse * pulsesPerSongPositionUnit
    static let maximumSongPosition: UInt16 = 16_383
    static let maximumSongPositionTicks: Int64 = Int64(maximumSongPosition) * ticksPerSongPositionUnit
    /// The tempo range of `TempoSegment`.
    static let microsPerQuarterRange: ClosedRange<Int64> = 60_000...3_000_000

    /// The tick of the zero-based pulse `pulse`.
    static func ticks(forPulse pulse: Int64) throws(MIDIClockError) -> Int64 {
        guard pulse >= 0 else { throw .negativePulse(pulse) }
        let (ticks, overflow) = pulse.multipliedReportingOverflow(by: ticksPerPulse)
        guard !overflow else { throw .positionOverflow }
        return ticks
    }

    /// The tick of a Song Position Pointer (0...16,383 sixteenths).
    static func ticks(forSongPosition position: UInt16) throws(MIDIClockError) -> Int64 {
        guard position <= maximumSongPosition else { throw .songPositionOutOfRange(Int64(position)) }
        return Int64(position) * ticksPerSongPositionUnit
    }

    /// Decodes the 14-bit pointer from its LSB-first data bytes.
    static func songPosition(lsb: UInt8, msb: UInt8) throws(MIDIClockError) -> UInt16 {
        guard lsb < 0x80 else { throw .invalidDataByte(lsb) }
        guard msb < 0x80 else { throw .invalidDataByte(msb) }
        return UInt16(lsb) | UInt16(msb) << 7
    }

    /// The LSB-first data bytes of a pointer.
    static func songPositionBytes(_ position: UInt16) throws(MIDIClockError) -> (lsb: UInt8, msb: UInt8) {
        guard position <= maximumSongPosition else { throw .songPositionOutOfRange(Int64(position)) }
        return (UInt8(position & 0x7F), UInt8(position >> 7))
    }

    /// The last pointer at or before `ticks`, plus the whole pulses and ticks after it.
    /// Positions past the last pointer's sixteenth are refused.
    static func songPosition(atOrBeforeTicks ticks: Int64) throws(MIDIClockError) -> MIDISongPositionSplit {
        guard ticks >= 0 else { throw .negativeTicks(ticks) }
        let units = ticks / ticksPerSongPositionUnit
        guard units <= Int64(maximumSongPosition) else { throw .songPositionOutOfRange(units) }
        let remainder = ticks % ticksPerSongPositionUnit
        return MIDISongPositionSplit(position: UInt16(units),
                                     remainderPulses: remainder / ticksPerPulse,
                                     remainderTicks: remainder % ticksPerPulse)
    }
}
