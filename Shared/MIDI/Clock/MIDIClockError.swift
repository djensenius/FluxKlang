//
//  MIDIClockError.swift
//  FluxKlang
//
//  Typed refusals of the pure MIDI clock math. Every throwing call leaves the
//  receiver's state unchanged.
//

/// Why a MIDI clock conversion, message or observation was refused.
enum MIDIClockError: Error, Equatable, Sendable {
    case negativePulse(Int64)
    case negativeTicks(Int64)
    case positionOverflow
    case songPositionOutOfRange(Int64)
    case invalidDataByte(UInt8)
    case missingSongPositionData
    case nonMonotonicHost(previous: UInt64, current: UInt64)
    case nonMonotonicPulse(previous: Int64, current: Int64)
    case invalidTimebase
    case invalidWindow(Int)
    case invalidLag(Int)
    case tempoOutOfRange(Int64)
    case invalidBlock(startFrame: Int64, frameCount: Int64)
    case invalidCapacity(Int)
    case pulseCapacityExceeded(capacity: Int)
    case clockMap(ClockMapError)
}
