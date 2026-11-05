//
//  MIDIClockMessage.swift
//  FluxKlang
//
//  The MIDI 1 messages that drive musical clock sync. Tick (F9) and Active
//  Sensing (FE) are deliberately not clock messages here; the Active Sensing
//  timeout belongs to the I/O lanes (#80/#81). Not for the render thread:
//  `bytes()` allocates.
//

enum MIDIClockMessage: Equatable, Sendable {
    case clock
    case start
    case `continue`
    case stop
    case songPosition(UInt16)

    /// Nil for messages unrelated to clock sync; throws for a malformed Song Position Pointer.
    init?(_ event: MIDI1Event) throws(MIDIClockError) {
        switch event {
        case let .realTime(status):
            self.init(realTimeStatus: status)
        case let .systemCommon(0xF2, data1, data2):
            guard let data1, let data2 else { throw .missingSongPositionData }
            self = .songPosition(try MIDIClockMath.songPosition(lsb: data1, msb: data2))
        default:
            return nil
        }
    }

    /// Nil for messages unrelated to clock sync.
    init?(_ semantic: MIDI1Semantic) throws(MIDIClockError) {
        switch semantic {
        case let .realTime(status):
            self.init(realTimeStatus: status)
        case let .systemCommon(status, data1, data2):
            try self.init(MIDI1Event.systemCommon(status: status, data1: data1, data2: data2))
        default:
            return nil
        }
    }

    private init?(realTimeStatus status: UInt8) {
        switch status {
        case 0xF8: self = .clock
        case 0xFA: self = .start
        case 0xFB: self = .continue
        case 0xFC: self = .stop
        default: return nil
        }
    }

    /// The outgoing MIDI 1 bytes.
    func bytes() throws(MIDIClockError) -> [UInt8] {
        switch self {
        case .clock: return [0xF8]
        case .start: return [0xFA]
        case .continue: return [0xFB]
        case .stop: return [0xFC]
        case let .songPosition(position):
            let data = try MIDIClockMath.songPositionBytes(position)
            return [0xF2, data.lsb, data.msb]
        }
    }
}
