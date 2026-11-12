/// The System Common and System Real Time messages of MT 0x1 (M2-104-UM, System Messages), without the group.
///
/// Status bytes and data layout match MIDI 1.0. Cross-checked against Apple CoreMIDI `MIDIMessages.h`
/// (`MIDISystemStatus`, `MIDI1UPSystemCommon`) and Linux `include/sound/ump_msg.h` (`UMP_SYSTEM_STATUS_*`).
enum UMPSystemMessage: Equatable, Sendable {
    /// 0xF1 MIDI Time Code quarter frame. The raw data byte `0nnndddd`; piece and nibble checks are
    /// `MTCQuarterFrame`'s job.
    case mtcQuarterFrame(UMPSevenBit)
    /// 0xF2 Song Position Pointer: MIDI beats (sixteenth notes) since the song start, 14 bits (0...0x3FFF).
    case songPositionPointer(UInt16)
    /// 0xF3 Song Select.
    case songSelect(UMPSevenBit)
    /// 0xF6 Tune Request.
    case tuneRequest
    /// 0xF8 Timing Clock.
    case timingClock
    /// 0xFA Start.
    case start
    /// 0xFB Continue.
    case `continue`
    /// 0xFC Stop.
    case stop
    /// 0xFE Active Sensing.
    case activeSensing
    /// 0xFF Reset.
    case reset

    /// The largest Song Position Pointer two 7-bit data bytes can carry.
    static let maximumSongPosition: UInt16 = 0x3FFF
}

/// One UMP System Common or System Real Time message (MT 0x1):
/// `[0x1 | group][status][data byte 1][data byte 2]`, one 32-bit word.
///
/// MT 0x1 carries a Group (`UMPMessageType.carriesGroup`), so the group is part of the value and is never
/// reserved. Song Position Pointer is sent LSB in data byte 1, MSB in data byte 2, as in MIDI 1.0.
///
/// Decoding refuses, in this order: another message type (`wrongMessageType`); a status that MT 0x1 does not
/// define (`reservedStatus`): below 0xF0, SysEx 0xF0/0xF7 (SysEx is MT 0x3), and the undefined 0xF4, 0xF5, 0xF9,
/// 0xFD; then any non-zero reserved bit (`reservedBitsSet`): bit 7 of a used data byte, or any bit of an unused
/// data byte. So a decoded message always re-encodes to the received word.
/// This type is a codec only: translation between UMP and MIDI 1.0 byte streams does not use it yet.
struct UMPSystemCommonRealTime: Equatable, Sendable {
    let group: UMPGroup
    let message: UMPSystemMessage

    /// Refuses a Song Position Pointer above 0x3FFF; every other message encodes.
    init(group: UMPGroup, message: UMPSystemMessage) throws(UMPRefusal) {
        if case let .songPositionPointer(beats) = message, beats > UMPSystemMessage.maximumSongPosition {
            throw .valueOutOfRange(field: .fourteenBit, value: Int(beats))
        }
        self.group = group
        self.message = message
    }

    init(decoding packet: UMPPacket) throws(UMPRefusal) {
        guard packet.messageType == .system else {
            throw .wrongMessageType(expected: .system, actual: packet.messageType)
        }
        let word = packet.words[0]
        let status = UInt8(truncatingIfNeeded: word >> 16)
        guard let count = Self.dataByteCount(status: status) else { throw .reservedStatus(mt: .system, status: status) }
        let reservedMask: UInt32
        switch count {
        case 0: reservedMask = 0xFFFF
        case 1: reservedMask = 0x80FF
        default: reservedMask = 0x8080
        }
        guard word & reservedMask == 0 else { throw .reservedBitsSet(mt: .system, status: status) }
        let group = try UMPGroup(UInt8((word >> 24) & 0x0F))
        let message = try Self.message(status: status, data1: UInt8(truncatingIfNeeded: word >> 8),
                                       data2: UInt8(truncatingIfNeeded: word))
        try self.init(group: group, message: message)
    }

    /// Accepts the shapes `MIDI1Parser` produces: `.systemCommon` for 0xF1...0xF6 with exactly the data bytes the
    /// status uses (nil for the rest), and `.realTime` for 0xF8...0xFF.
    ///
    /// Refuses, in this order: `.channel`, `.sysEx`, a channel status (below 0xF0) in either case, or a `.realTime`
    /// status below 0xF8 with `notSystemMessage`; a status MT 0x1 does not define (a lone 0xF7, undefined
    /// 0xF4/0xF5/0xF9/0xFD) with `reservedStatus`; any other shape mismatch (wrong case for the status, data bytes
    /// present or missing contrary to it) with `notSystemMessage`; a data byte above 0x7F with
    /// `valueOutOfRange(field: .sevenBit, ...)`.
    init(group: UMPGroup, event: MIDI1Event) throws(UMPRefusal) {
        let status: UInt8
        let data1: UInt8?
        let data2: UInt8?
        let isRealTime: Bool
        switch event {
        case let .systemCommon(commonStatus, commonData1, commonData2):
            (status, data1, data2, isRealTime) = (commonStatus, commonData1, commonData2, false)
        case let .realTime(realTimeStatus):
            (status, data1, data2, isRealTime) = (realTimeStatus, nil, nil, true)
        case .channel, .sysEx:
            throw .notSystemMessage
        }
        guard status >= 0xF0, !isRealTime || status >= 0xF8 else { throw .notSystemMessage }
        guard let count = Self.dataByteCount(status: status) else { throw .reservedStatus(mt: .system, status: status) }
        guard (status >= 0xF8) == isRealTime, (data1 != nil) == (count >= 1), (data2 != nil) == (count == 2) else {
            throw .notSystemMessage
        }
        for byte in [data1, data2].compactMap({ $0 }) where byte >= 0x80 {
            throw .valueOutOfRange(field: .sevenBit, value: Int(byte))
        }
        try self.init(group: group, message: Self.message(status: status, data1: data1 ?? 0, data2: data2 ?? 0))
    }

    /// The `MIDI1Event` in `MIDI1Parser`'s shape: `.realTime` for 0xF8...0xFF, otherwise `.systemCommon` with nil
    /// for each data byte the status does not use.
    var event: MIDI1Event {
        let bytes = self.bytes
        if bytes.status >= 0xF8 { return .realTime(status: bytes.status) }
        return .systemCommon(status: bytes.status, data1: bytes.data1, data2: bytes.data2)
    }

    var packet: UMPPacket {
        let bytes = self.bytes
        return .system(UInt32(group.value) << 24 | UInt32(bytes.status) << 16 | UInt32(bytes.data1 ?? 0) << 8
            | UInt32(bytes.data2 ?? 0))
    }

    /// The defined MT 0x1 statuses that carry no data bytes.
    private static let datalessMessages: [UInt8: UMPSystemMessage] = [
        0xF6: .tuneRequest, 0xF8: .timingClock, 0xFA: .start, 0xFB: .continue, 0xFC: .stop, 0xFE: .activeSensing,
        0xFF: .reset
    ]

    /// Data bytes each defined MT 0x1 status uses, or nil for a status MT 0x1 does not define.
    private static func dataByteCount(status: UInt8) -> Int? {
        switch status {
        case 0xF1, 0xF3:
            return 1
        case 0xF2:
            return 2
        default:
            return datalessMessages[status] == nil ? nil : 0
        }
    }

    /// The message for a defined status whose used data bytes are 7-bit.
    private static func message(status: UInt8, data1: UInt8, data2: UInt8) throws(UMPRefusal) -> UMPSystemMessage {
        switch status {
        case 0xF1:
            return .mtcQuarterFrame(try UMPSevenBit(data1))
        case 0xF2:
            return .songPositionPointer(UInt16(data1) | UInt16(data2) << 7)
        case 0xF3:
            return .songSelect(try UMPSevenBit(data1))
        default:
            guard let message = datalessMessages[status] else { throw .reservedStatus(mt: .system, status: status) }
            return message
        }
    }

    /// Status and the data bytes the status uses, as MIDI 1.0 sends them.
    private var bytes: UMPSystemBytes {
        switch message {
        case let .mtcQuarterFrame(data): return UMPSystemBytes(status: 0xF1, data1: data.value)
        case let .songPositionPointer(beats):
            return UMPSystemBytes(status: 0xF2, data1: UInt8(beats & 0x7F),
                                  data2: UInt8(truncatingIfNeeded: beats >> 7))
        case let .songSelect(song): return UMPSystemBytes(status: 0xF3, data1: song.value)
        case .tuneRequest: return UMPSystemBytes(status: 0xF6)
        case .timingClock: return UMPSystemBytes(status: 0xF8)
        case .start: return UMPSystemBytes(status: 0xFA)
        case .continue: return UMPSystemBytes(status: 0xFB)
        case .stop: return UMPSystemBytes(status: 0xFC)
        case .activeSensing: return UMPSystemBytes(status: 0xFE)
        case .reset: return UMPSystemBytes(status: 0xFF)
        }
    }
}

/// Status byte and the data bytes (nil when unused) of one MT 0x1 message.
private struct UMPSystemBytes {
    let status: UInt8
    var data1: UInt8?
    var data2: UInt8?
}
