/// Channel numbers are 1...16, matching the existing Launch Control mapping.
/// Note On zero normalizes to release velocity 64; explicit Note Off retains its transmitted release velocity.
enum MIDI1Semantic: Equatable, Sendable {
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case polyphonicPressure(channel: UInt8, note: UInt8, pressure: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case channelPressure(channel: UInt8, pressure: UInt8)
    case pitchBend(channel: UInt8, value: UInt16)
    case systemCommon(status: UInt8, data1: UInt8?, data2: UInt8?)
    case realTime(status: UInt8)
    case sysEx(payload: [UInt8])
}

extension MIDI1Event {
    /// Refuses forged status/length/data combinations; raw cases are intentionally internal and constructible.
    var semantic: MIDI1Semantic? {
        switch self {
        case let .channel(status, data1, data2):
            return channelSemantic(status: status, data1: data1, data2: data2)
        case let .systemCommon(status, data1, data2):
            guard Self.validCommon(status: status, data1: data1, data2: data2) else { return nil }
            return .systemCommon(status: status, data1: data1, data2: data2)
        case let .realTime(status):
            guard status >= 0xF8 else { return nil }
            return .realTime(status: status)
        case let .sysEx(payload):
            guard payload.allSatisfy({ $0 < 0x80 }) else { return nil }
            return .sysEx(payload: payload)
        }
    }

    private func channelSemantic(status: UInt8, data1: UInt8, data2: UInt8?) -> MIDI1Semantic? {
        guard (0x80...0xEF).contains(status), data1 < 0x80 else { return nil }
        let channel = (status & 0x0F) + 1
        let family = status & 0xF0
        if family == 0xC0 || family == 0xD0 {
            guard data2 == nil else { return nil }
            return family == 0xC0
                ? .programChange(channel: channel, program: data1)
                : .channelPressure(channel: channel, pressure: data1)
        }
        guard let data2, data2 < 0x80 else { return nil }
        switch family {
        case 0x80:
            return .noteOff(channel: channel, note: data1, velocity: data2)
        case 0x90:
            // Note On velocity zero means Note Off with release velocity 64 (RFC 6295 Appendix A.7).
            return data2 == 0
                ? .noteOff(channel: channel, note: data1, velocity: 64)
                : .noteOn(channel: channel, note: data1, velocity: data2)
        case 0xA0:
            return .polyphonicPressure(channel: channel, note: data1, pressure: data2)
        case 0xB0:
            return .controlChange(channel: channel, controller: data1, value: data2)
        case 0xE0:
            return .pitchBend(channel: channel, value: UInt16(data1) | (UInt16(data2) << 7))
        default:
            return nil
        }
    }

    private static func validCommon(status: UInt8, data1: UInt8?, data2: UInt8?) -> Bool {
        switch status {
        case 0xF1, 0xF3:
            return data1.map { $0 < 0x80 } == true && data2 == nil
        case 0xF2:
            return data1.map { $0 < 0x80 } == true && data2.map { $0 < 0x80 } == true
        case 0xF4...0xF7:
            return data1 == nil && data2 == nil
        default:
            return false
        }
    }
}
