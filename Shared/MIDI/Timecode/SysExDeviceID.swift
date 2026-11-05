/// Universal SysEx device ID 0x00...0x7F; 0x7F is the all-call address.
struct SysExDeviceID: Equatable, Hashable, Sendable {
    static let allCall = SysExDeviceID(validated: 0x7F)
    /// Universal Real Time SysEx ID (first payload byte after F0).
    static let universalRealTime: UInt8 = 0x7F

    let rawValue: UInt8

    init(_ rawValue: UInt8) throws(TimecodeError) {
        guard rawValue < 0x80 else { throw .deviceIDOutOfRange(rawValue) }
        self.rawValue = rawValue
    }

    private init(validated rawValue: UInt8) {
        self.rawValue = rawValue
    }

    var isAllCall: Bool { rawValue == 0x7F }

    /// A message addressed to this ID is meant for `receiver`: exact match or all-call.
    func addresses(_ receiver: SysExDeviceID) -> Bool {
        isAllCall || self == receiver
    }
}

/// Shared framing for Universal Real Time messages as `MIDI1Parser` delivers them (payload without F0/F7).
enum UniversalRealTimeSysEx {
    /// Returns the device ID when `payload` is `7F <dev> <subID1> <subID2?> …`, otherwise nil.
    static func deviceID(in payload: [UInt8], subIDs: [UInt8]) throws(TimecodeError) -> SysExDeviceID? {
        guard payload.count >= 2 + subIDs.count, payload[0] == universalRealTime,
              Array(payload[2..<(2 + subIDs.count)]) == subIDs else { return nil }
        if let bad = payload.first(where: { $0 >= 0x80 }) { throw .dataByteOutOfRange(bad) }
        return try SysExDeviceID(payload[1])
    }

    static func framed(_ payload: [UInt8]) -> [UInt8] {
        [0xF0] + payload + [0xF7]
    }

    private static let universalRealTime = SysExDeviceID.universalRealTime
}
