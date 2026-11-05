/// MTC Full Message `F0 7F <dev> 01 01 hr mn sc fr F7`, hr = `0rrhhhhh` with rr the rate code.
struct MTCFullFrame: Equatable, Hashable, Sendable {
    static let subIDs: [UInt8] = [0x01, 0x01]
    /// Payload length as `MIDI1Parser` delivers it (no F0/F7).
    static let payloadLength = 8

    let deviceID: SysExDeviceID
    let time: SMPTETime

    init(deviceID: SysExDeviceID, time: SMPTETime) {
        self.deviceID = deviceID
        self.time = time
    }

    init(sysExPayload payload: [UInt8]) throws(TimecodeError) {
        guard let deviceID = try UniversalRealTimeSysEx.deviceID(in: payload, subIDs: Self.subIDs) else {
            throw .notTimecodeMessage
        }
        guard payload.count == Self.payloadLength else {
            throw .lengthMismatch(expected: Self.payloadLength, actual: payload.count)
        }
        self.deviceID = deviceID
        time = try SMPTETime(packedHours: payload[4], minutes: payload[5], seconds: payload[6], frames: payload[7])
    }

    init(event: MIDI1Event) throws(TimecodeError) {
        guard case let .sysEx(payload) = event else { throw .notTimecodeMessage }
        try self.init(sysExPayload: payload)
    }

    /// Returns nil for a well-formed full frame addressed to another device.
    static func decode(_ event: MIDI1Event, receiver: SysExDeviceID) throws(TimecodeError) -> MTCFullFrame? {
        let frame = try MTCFullFrame(event: event)
        return frame.deviceID.addresses(receiver) ? frame : nil
    }

    var sysExPayload: [UInt8] {
        [SysExDeviceID.universalRealTime, deviceID.rawValue] + Self.subIDs + time.packedFields
    }

    var event: MIDI1Event { .sysEx(payload: sysExPayload) }
    var bytes: [UInt8] { UniversalRealTimeSysEx.framed(sysExPayload) }
}

extension SMPTETime {
    /// Decodes the `0rrhhhhh mm ss ff` layout shared by the MTC full frame and MMC standard time code.
    init(packedHours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8) throws(TimecodeError) {
        for byte in [packedHours, minutes, seconds, frames] where byte >= 0x80 { throw .dataByteOutOfRange(byte) }
        try self.init(hours: Int(packedHours & 0x1F), minutes: Int(minutes), seconds: Int(seconds),
                      frames: Int(frames), rate: SMPTEFrameRate(code: packedHours >> 5))
    }

    var packedFields: [UInt8] {
        [rate.rawValue << 5 | UInt8(hours), UInt8(minutes), UInt8(seconds), UInt8(frames)]
    }
}
