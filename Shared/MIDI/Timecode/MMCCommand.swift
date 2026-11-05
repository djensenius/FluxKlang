/// Locate target in MMC standard time code: `hr mn sc fr ff`, hr = `0tthhhhh`.
/// mn bit 6 is the colour-frame flag, preserved separately from the time; blank (sc bit 6), sign (fr bit 6)
/// and final-byte-ID (fr bit 5) flags are refused. ff is subframes 0...99.
struct MMCLocateTarget: Equatable, Hashable, Sendable {
    static let maximumSubframes = 99
    static let colorFrameBit: UInt8 = 0x40

    let time: SMPTETime
    let subframes: Int
    let colorFrame: Bool

    init(time: SMPTETime, subframes: Int = 0, colorFrame: Bool = false) throws(TimecodeError) {
        guard (0...Self.maximumSubframes).contains(subframes) else {
            throw .fieldOutOfRange(.subframes, value: subframes)
        }
        self.time = time
        self.subframes = subframes
        self.colorFrame = colorFrame
    }

    fileprivate init(fields: ArraySlice<UInt8>) throws(TimecodeError) {
        let bytes = Array(fields)
        for byte in bytes[2...3] where byte & 0x40 != 0 { throw .reservedFlagsSet(byte: byte) }
        if bytes[3] & 0x20 != 0 { throw .reservedFlagsSet(byte: bytes[3]) }
        guard bytes[4] < 0x80 else { throw .dataByteOutOfRange(bytes[4]) }
        let minutes = bytes[1] & ~Self.colorFrameBit
        try self.init(time: SMPTETime(packedHours: bytes[0], minutes: minutes, seconds: bytes[2], frames: bytes[3]),
                      subframes: Int(bytes[4]), colorFrame: bytes[1] & Self.colorFrameBit != 0)
    }

    fileprivate var fields: [UInt8] {
        var fields = time.packedFields + [UInt8(subframes)]
        if colorFrame { fields[1] |= Self.colorFrameBit }
        return fields
    }
}

/// The MMC commands this slice decodes and encodes. Values only; no transport authority.
enum MMCCommand: Equatable, Hashable, Sendable {
    case stop
    case play
    case deferredPlay
    case fastForward
    case rewind
    case recordStrobe
    case recordExit
    case pause
    case locate(MMCLocateTarget)

    static let locateCode: UInt8 = 0x44
    /// Locate byte count and TARGET sub-command (`44 06 01 hr mn sc fr ff`).
    static let locateTargetCount: UInt8 = 0x06
    static let locateTargetForm: UInt8 = 0x01

    private static let simple: [(UInt8, MMCCommand)] = [
        (0x01, .stop), (0x02, .play), (0x03, .deferredPlay), (0x04, .fastForward),
        (0x05, .rewind), (0x06, .recordStrobe), (0x07, .recordExit), (0x09, .pause)
    ]

    var code: UInt8 {
        if case .locate = self { return Self.locateCode }
        return Self.simple.first { $0.1 == self }?.0 ?? Self.locateCode
    }

    /// Command bytes after the `06` sub-ID.
    var commandBytes: [UInt8] {
        guard case let .locate(target) = self else { return [code] }
        return [Self.locateCode, Self.locateTargetCount, Self.locateTargetForm] + target.fields
    }

    /// Decodes exactly one command occupying all of `bytes`; bytes after a complete command are refused
    /// as `.multipleMMCCommands` without parsing either command.
    init(commandBytes bytes: ArraySlice<UInt8>) throws(TimecodeError) {
        guard let code = bytes.first else { throw .lengthMismatch(expected: 1, actual: 0) }
        if let command = Self.simple.first(where: { $0.0 == code })?.1 {
            guard bytes.count == 1 else {
                throw .multipleMMCCommands(firstCommandLength: 1, totalLength: bytes.count)
            }
            self = command
            return
        }
        guard code == Self.locateCode else { throw .unsupportedMMCCommand(code) }
        let expected = 3 + 5
        guard bytes.count >= 3 else { throw .lengthMismatch(expected: expected, actual: bytes.count) }
        let start = bytes.startIndex
        guard bytes[start + 2] == Self.locateTargetForm else { throw .unsupportedLocateForm(bytes[start + 2]) }
        guard bytes[start + 1] == Self.locateTargetCount else {
            throw .lengthMismatch(expected: Int(Self.locateTargetCount), actual: Int(bytes[start + 1]))
        }
        guard bytes.count >= expected else { throw .lengthMismatch(expected: expected, actual: bytes.count) }
        guard bytes.count == expected else {
            throw .multipleMMCCommands(firstCommandLength: expected, totalLength: bytes.count)
        }
        self = try .locate(MMCLocateTarget(fields: bytes.dropFirst(3)))
    }
}

/// MMC command message `F0 7F <dev> 06 <command…> F7` carrying exactly one command.
struct MMCMessage: Equatable, Hashable, Sendable {
    static let subID: UInt8 = 0x06

    let deviceID: SysExDeviceID
    let command: MMCCommand

    init(deviceID: SysExDeviceID, command: MMCCommand) {
        self.deviceID = deviceID
        self.command = command
    }

    init(sysExPayload payload: [UInt8]) throws(TimecodeError) {
        guard let deviceID = try UniversalRealTimeSysEx.deviceID(in: payload, subIDs: [Self.subID]) else {
            throw .notMMCCommand
        }
        self.deviceID = deviceID
        command = try MMCCommand(commandBytes: payload.dropFirst(3))
    }

    init(event: MIDI1Event) throws(TimecodeError) {
        guard case let .sysEx(payload) = event else { throw .notMMCCommand }
        try self.init(sysExPayload: payload)
    }

    /// Returns nil for a well-formed command addressed to another device.
    static func decode(_ event: MIDI1Event, receiver: SysExDeviceID) throws(TimecodeError) -> MMCMessage? {
        let message = try MMCMessage(event: event)
        return message.deviceID.addresses(receiver) ? message : nil
    }

    var sysExPayload: [UInt8] {
        [SysExDeviceID.universalRealTime, deviceID.rawValue, Self.subID] + command.commandBytes
    }

    var event: MIDI1Event { .sysEx(payload: sysExPayload) }
    var bytes: [UInt8] { UniversalRealTimeSysEx.framed(sysExPayload) }
}
