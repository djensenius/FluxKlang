/// MIDI 1.0 wire bytes for one message, the output side of `MIDI1Parser` (#81, slice MWB1).
/// Every message is sent whole with its status byte; see `MIDI1RunningStatusWriter` for running status.
/// Nothing calls it yet.
enum MIDI1Wire {
    /// The bytes of one semantic message. A Note On with velocity 0 is refused; send `.noteOff` for a release.
    static func bytes(_ message: MIDI1Semantic) throws(MIDI1WireRefusal) -> [UInt8] {
        switch message {
        case let .noteOff(channel, note, velocity):
            return try channelBytes(0x80, channel, [note, velocity])
        case let .noteOn(channel, note, velocity):
            return try noteOnBytes(channel: channel, note: note, velocity: velocity)
        case let .polyphonicPressure(channel, note, pressure):
            return try channelBytes(0xA0, channel, [note, pressure])
        case let .controlChange(channel, controller, value):
            return try channelBytes(0xB0, channel, [controller, value])
        case let .programChange(channel, program):
            return try channelBytes(0xC0, channel, [program])
        case let .channelPressure(channel, pressure):
            return try channelBytes(0xD0, channel, [pressure])
        case let .pitchBend(channel, value):
            return try pitchBendBytes(channel: channel, value: value)
        case let .systemCommon(status, data1, data2):
            return try systemCommonBytes(status: status, data1: data1, data2: data2)
        case let .realTime(status):
            return try realTimeBytes(status: status)
        case let .sysEx(payload):
            return try sysExBytes(payload)
        }
    }

    /// The bytes of one event. A channel event is sent exactly as held; the other cases are checked like the
    /// semantic cases of the same name.
    static func bytes(event: MIDI1Event) throws(MIDI1WireRefusal) -> [UInt8] {
        switch event {
        case let .channel(status, data1, data2):
            return try eventChannelBytes(status: status, data1: data1, data2: data2)
        case let .systemCommon(status, data1, data2):
            return try systemCommonBytes(status: status, data1: data1, data2: data2)
        case let .realTime(status):
            return try realTimeBytes(status: status)
        case let .sysEx(payload):
            return try sysExBytes(payload)
        }
    }

    private static func channelBytes(
        _ family: UInt8, _ channel: UInt8, _ data: [UInt8]
    ) throws(MIDI1WireRefusal) -> [UInt8] {
        guard (1...16).contains(channel) else { throw .channelOutOfRange(channel) }
        try checkData(data)
        return [family | (channel - 1)] + data
    }

    private static func noteOnBytes(channel: UInt8, note: UInt8, velocity: UInt8) throws(MIDI1WireRefusal) -> [UInt8] {
        let bytes = try channelBytes(0x90, channel, [note, velocity])
        if velocity == 0 { throw .noteOnVelocityZero(channel: channel, note: note) }
        return bytes
    }

    private static func pitchBendBytes(channel: UInt8, value: UInt16) throws(MIDI1WireRefusal) -> [UInt8] {
        guard (1...16).contains(channel) else { throw .channelOutOfRange(channel) }
        guard value <= 0x3FFF else { throw .pitchBendOutOfRange(value) }
        return [0xE0 | (channel - 1), UInt8(value & 0x7F), UInt8(value >> 7)]
    }

    private static func eventChannelBytes(
        status: UInt8, data1: UInt8, data2: UInt8?
    ) throws(MIDI1WireRefusal) -> [UInt8] {
        guard (0x80...0xEF).contains(status) else { throw .channelStatus(status) }
        let family = status & 0xF0
        let oneData = family == 0xC0 || family == 0xD0
        guard oneData == (data2 == nil) else { throw .channelDataShape(status: status) }
        let data = [data1] + (data2.map { [$0] } ?? [])
        try checkData(data)
        return [status] + data
    }

    private static func systemCommonBytes(
        status: UInt8, data1: UInt8?, data2: UInt8?
    ) throws(MIDI1WireRefusal) -> [UInt8] {
        let expected: (first: Bool, second: Bool)
        switch status {
        case 0xF1, 0xF3: expected = (true, false)
        case 0xF2: expected = (true, true)
        case 0xF6: expected = (false, false)
        default: throw .unsupportedSystemCommon(status)
        }
        guard (data1 != nil) == expected.first, (data2 != nil) == expected.second else {
            throw .systemCommonDataShape(status: status)
        }
        let data = [data1, data2].compactMap { $0 }
        try checkData(data)
        return [status] + data
    }

    private static func realTimeBytes(status: UInt8) throws(MIDI1WireRefusal) -> [UInt8] {
        switch status {
        case 0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF: return [status]
        default: throw .unsupportedRealTime(status)
        }
    }

    private static func sysExBytes(_ payload: [UInt8]) throws(MIDI1WireRefusal) -> [UInt8] {
        if let index = payload.firstIndex(where: { $0 >= 0x80 }) {
            throw .sysExByteHigh(index: index, byte: payload[index])
        }
        return [0xF0] + payload + [0xF7]
    }

    private static func checkData(_ data: [UInt8]) throws(MIDI1WireRefusal) {
        if let byte = data.first(where: { $0 >= 0x80 }) { throw .dataByteHigh(byte) }
    }
}
