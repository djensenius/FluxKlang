/// The status nibble of an MT 0x3 SysEx7 packet (M2-104-UM, Data Messages (64-bit); CoreMIDI `MIDISysExStatus`).
///
/// This is the UMP-layer status. The kernel's `SysExChunkStatus` has the same values but is kept separate so the
/// protocol codec does not depend on the audio kernel; a later slice can bridge them.
enum UMPSysEx7Status: UInt8, CaseIterable, Equatable, Sendable {
    /// The whole message fits in this packet.
    case complete = 0x0
    case start = 0x1
    case `continue` = 0x2
    case end = 0x3
}

/// One UMP Data Message (64-bit) packet, MT 0x3, carrying up to six 7-bit SysEx bytes:
/// word 0 `[0x3 | group][status | number of bytes][byte 1][byte 2]`, word 1 `[byte 3][byte 4][byte 5][byte 6]`.
///
/// The bytes are SysEx payload without F0 and F7, as in `MIDI1Event.sysEx`. Bytes past the count are unused and
/// must be zero.
///
/// Decoding refuses, in this order: another message type (`wrongMessageType`), a status 0x4...0xF
/// (`reservedStatus`), a number of bytes 7...15 (`valueOutOfRange(field: .sysEx7ByteCount)`), then a data byte
/// with bit 7 set within the count or any non-zero bit past it (`reservedBitsSet`). So a decoded packet always
/// re-encodes to the received words. This type is a stateless codec; it does not assemble messages across packets.
struct UMPSysEx7Packet: Equatable, Sendable {
    /// The most data bytes one packet carries.
    static let maximumByteCount = 6

    let group: UMPGroup
    let status: UMPSysEx7Status
    /// 0...6 bytes, each 0...0x7F.
    let bytes: [UInt8]

    private init(validatedGroup group: UMPGroup, status: UMPSysEx7Status, bytes: [UInt8]) {
        self.group = group
        self.status = status
        self.bytes = bytes
    }

    /// Refuses more than six bytes (`valueOutOfRange(field: .sysEx7ByteCount)`) and a byte above 0x7F
    /// (`valueOutOfRange(field: .sevenBit)`).
    init(group: UMPGroup, status: UMPSysEx7Status, bytes: [UInt8]) throws(UMPRefusal) {
        guard bytes.count <= Self.maximumByteCount else {
            throw .valueOutOfRange(field: .sysEx7ByteCount, value: bytes.count)
        }
        for byte in bytes where byte >= 0x80 {
            throw .valueOutOfRange(field: .sevenBit, value: Int(byte))
        }
        self.init(validatedGroup: group, status: status, bytes: bytes)
    }

    init(decoding packet: UMPPacket) throws(UMPRefusal) {
        guard packet.messageType == .data64 else {
            throw .wrongMessageType(expected: .data64, actual: packet.messageType)
        }
        let (first, second) = (packet.words[0], packet.words[1])
        let statusNibble = UInt8((first >> 20) & 0x0F)
        guard let status = UMPSysEx7Status(rawValue: statusNibble) else {
            throw .reservedStatus(mt: .data64, status: statusNibble)
        }
        let count = Int((first >> 16) & 0x0F)
        guard count <= Self.maximumByteCount else { throw .valueOutOfRange(field: .sysEx7ByteCount, value: count) }
        let slots = [first >> 8, first, second >> 24, second >> 16, second >> 8, second].map {
            UInt8(truncatingIfNeeded: $0)
        }
        let used = slots.prefix(count)
        guard used.allSatisfy({ $0 < 0x80 }), slots.dropFirst(count).allSatisfy({ $0 == 0 }) else {
            throw .reservedBitsSet(mt: .data64, status: statusNibble)
        }
        // The group nibble is four bits, so it is always in range.
        self.init(validatedGroup: try UMPGroup(UInt8((first >> 24) & 0x0F)), status: status, bytes: Array(used))
    }

    /// The two-word packet; unused byte slots are zero.
    var packet: UMPPacket {
        var slots = [UInt32](repeating: 0, count: Self.maximumByteCount)
        for (index, byte) in bytes.enumerated() { slots[index] = UInt32(byte) }
        let first = UInt32(group.value) << 24 | UInt32(status.rawValue) << 20 | UInt32(bytes.count) << 16
            | slots[0] << 8 | slots[1]
        let second = slots[2] << 24 | slots[3] << 16 | slots[4] << 8 | slots[5]
        return .data64(first, second)
    }

    /// Frames a SysEx payload (without F0 and F7) as packets of up to six bytes: one `complete` packet if it fits
    /// (an empty payload gives one `complete` packet with no bytes), otherwise `start`, any `continue`, then `end`.
    /// Refuses a payload byte above 0x7F (`valueOutOfRange(field: .sevenBit)`); nothing is returned then.
    /// The splitter has no size bound of its own: callers must pass an already-bounded payload, for example one
    /// limited by `MIDI1Parser.maximumSysExPayloadBytes`.
    static func packets(group: UMPGroup, payload: [UInt8]) throws(UMPRefusal) -> [UMPSysEx7Packet] {
        for byte in payload where byte >= 0x80 {
            throw .valueOutOfRange(field: .sevenBit, value: Int(byte))
        }
        guard payload.count > maximumByteCount else {
            return [UMPSysEx7Packet(validatedGroup: group, status: .complete, bytes: payload)]
        }
        let starts = Array(stride(from: 0, to: payload.count, by: maximumByteCount))
        return starts.enumerated().map { index, offset in
            let status: UMPSysEx7Status
            if index == 0 {
                status = .start
            } else if index == starts.count - 1 {
                status = .end
            } else {
                status = .continue
            }
            let chunk = Array(payload[offset..<min(offset + maximumByteCount, payload.count)])
            return UMPSysEx7Packet(validatedGroup: group, status: status, bytes: chunk)
        }
    }
}
