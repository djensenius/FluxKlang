// MT 0x5 layouts follow M2-104-UM, Data Messages (128-bit), cross-checked against Apple CoreMIDI `MIDIMessages.h`
// (`kMIDIMessageTypeData128`, `MIDISysExStatus` 0x0...0x3, 0x8, 0x9), cmidi2.h (`cmidi2_ump_get_sysex8_*`,
// `cmidi2_ump_get_mds_*`), AM_MIDI2.0Lib (`umpProcessor` MT 0x5, `mt5MDSHeader`, `mt5MDSPayload`) and MIDI2.0Workbench
// `messageTypes.js`. A packet is read as sixteen bytes, most significant first; byte 0 is `[0x5 | group]` and the
// high nibble of byte 1 is the status.

/// The status nibble of an MT 0x5 SysEx8 packet (M2-104-UM, Data Messages (128-bit); CoreMIDI `MIDISysExStatus`).
///
/// The values match `UMPSysEx7Status`; the types are kept apart so each codec names only its own message type.
enum UMPSysEx8Status: UInt8, CaseIterable, Equatable, Sendable {
    /// The whole message fits in this packet.
    case complete = 0x0
    case start = 0x1
    case `continue` = 0x2
    case end = 0x3
}

/// One UMP Data Message (128-bit) SysEx8 packet, MT 0x5 status 0x0...0x3, carrying a Stream ID and up to thirteen
/// 8-bit bytes: byte 1 `[status | number of bytes]`, byte 2 the Stream ID, bytes 3...15 the data.
///
/// The number of bytes counts the Stream ID too, so it is 1...14 for 0...13 data bytes (cmidi2
/// `cmidi2_ump_get_sysex8_data` subtracts one; bl-midi2-rs `ValidPacketSizes` accepts only 1...14). Data bytes are
/// full 8-bit values. Bytes past the count are unused and must be zero.
struct UMPSysEx8Packet: Equatable, Sendable {
    /// The most data bytes one packet carries, not counting the Stream ID.
    static let maximumByteCount = 13

    let group: UMPGroup
    let status: UMPSysEx8Status
    let streamID: UInt8
    /// 0...13 bytes, each 0x00...0xFF.
    let bytes: [UInt8]

    fileprivate init(validatedGroup group: UMPGroup, status: UMPSysEx8Status, streamID: UInt8, bytes: [UInt8]) {
        self.group = group
        self.status = status
        self.streamID = streamID
        self.bytes = bytes
    }

    /// Refuses more than thirteen bytes with `valueOutOfRange(field: .sysEx8ByteCount)`; the value is the wire
    /// number of bytes, so it includes the Stream ID.
    init(group: UMPGroup, status: UMPSysEx8Status, streamID: UInt8, bytes: [UInt8]) throws(UMPRefusal) {
        guard bytes.count <= Self.maximumByteCount else {
            throw .valueOutOfRange(field: .sysEx8ByteCount, value: bytes.count + 1)
        }
        self.init(validatedGroup: group, status: status, streamID: streamID, bytes: bytes)
    }

    /// The four-word packet; unused byte slots are zero.
    var packet: UMPPacket {
        var slots = [UInt8](repeating: 0, count: UMPData128Message.packetByteCount)
        slots[0] = group.value
        slots[1] = status.rawValue << 4 | UInt8(bytes.count + 1)
        slots[2] = streamID
        slots.replaceSubrange(3..<(3 + bytes.count), with: bytes)
        return UMPData128Message.packet(slots)
    }

    /// Frames a SysEx8 payload (without F0 and F7) as packets of up to thirteen bytes, each tagged with `streamID`:
    /// one `complete` packet if it fits (an empty payload gives one `complete` packet with no data bytes, number of
    /// bytes 1), otherwise `start`, any `continue`, then `end`. Every byte value is allowed, so nothing is refused.
    /// The splitter has no size bound of its own: callers must pass an already-bounded payload.
    static func packets(group: UMPGroup, streamID: UInt8, payload: [UInt8]) -> [UMPSysEx8Packet] {
        guard payload.count > maximumByteCount else {
            return [UMPSysEx8Packet(validatedGroup: group, status: .complete, streamID: streamID, bytes: payload)]
        }
        let starts = Array(stride(from: 0, to: payload.count, by: maximumByteCount))
        return starts.enumerated().map { index, offset in
            let status: UMPSysEx8Status
            if index == 0 {
                status = .start
            } else if index == starts.count - 1 {
                status = .end
            } else {
                status = .continue
            }
            let chunk = Array(payload[offset..<min(offset + maximumByteCount, payload.count)])
            return UMPSysEx8Packet(validatedGroup: group, status: status, streamID: streamID, bytes: chunk)
        }
    }
}

/// The 4-bit Mixed Data Set ID carried in the low nibble of byte 1 of MT 0x5 status 0x8 and 0x9 packets, 0...15.
struct UMPMixedDataSetID: Equatable, Hashable, Sendable {
    private let storedValue: UInt8

    init(_ value: UInt8) throws(UMPRefusal) {
        guard value < 16 else { throw .valueOutOfRange(field: .mixedDataSetID, value: Int(value)) }
        storedValue = value
    }

    var value: UInt8 { storedValue }
}

/// One Mixed Data Set Header packet, MT 0x5 status 0x8. After the MDS ID, the remaining fourteen bytes are seven
/// big-endian 16-bit fields in this order (cmidi2 `cmidi2_ump_get_mds_*`, AM_MIDI2.0Lib `mt5MDSHeader`,
/// MIDI2.0Workbench bit ranges 16...127): word 0 low half, word 1 high and low half, and so on to word 3 low half.
///
/// Every bit is a field, so there are no reserved bits. The fields are kept as received: this codec does not check
/// that the chunk number is within the number of chunks, nor interpret the manufacturer, device or sub IDs.
struct UMPMixedDataSetHeader: Equatable, Sendable {
    let group: UMPGroup
    let mdsID: UMPMixedDataSetID
    /// Number of valid bytes in this message chunk (word 0 bits 15...0).
    let validByteCount: UInt16
    /// Number of chunks in the Mixed Data Set (word 1 bits 31...16).
    let chunkCount: UInt16
    /// Number of this chunk (word 1 bits 15...0).
    let chunkNumber: UInt16
    /// Word 2 bits 31...16.
    let manufacturerID: UInt16
    /// Word 2 bits 15...0.
    let deviceID: UInt16
    /// Sub ID #1, word 3 bits 31...16.
    let subID1: UInt16
    /// Sub ID #2, word 3 bits 15...0.
    let subID2: UInt16

    var packet: UMPPacket {
        let fields = [validByteCount, chunkCount, chunkNumber, manufacturerID, deviceID, subID1, subID2]
        let header = [group.value, UMPData128Message.mixedDataSetHeaderStatus << 4 | mdsID.value]
        return UMPData128Message.packet(header + fields.flatMap { [UInt8($0 >> 8), UInt8(truncatingIfNeeded: $0)] })
    }
}

/// One Mixed Data Set Payload packet, MT 0x5 status 0x9: the MDS ID, then exactly fourteen payload bytes in
/// bytes 2...15 (AM_MIDI2.0Lib `umpProcessor` status 9; MIDI2.0Workbench "Byte 1"..."Byte 14"). The packet has no
/// byte count, so all fourteen bytes are payload; padding in the last payload of a chunk is the receiver's business
/// (it knows the chunk's valid byte count from the header).
struct UMPMixedDataSetPayload: Equatable, Sendable {
    static let byteCount = 14

    let group: UMPGroup
    let mdsID: UMPMixedDataSetID
    /// Exactly fourteen bytes, each 0x00...0xFF.
    let bytes: [UInt8]

    fileprivate init(validatedGroup group: UMPGroup, mdsID: UMPMixedDataSetID, bytes: [UInt8]) {
        self.group = group
        self.mdsID = mdsID
        self.bytes = bytes
    }

    /// Refuses any byte count but fourteen (`valueOutOfRange(field: .mixedDataSetPayloadByteCount)`).
    init(group: UMPGroup, mdsID: UMPMixedDataSetID, bytes: [UInt8]) throws(UMPRefusal) {
        guard bytes.count == Self.byteCount else {
            throw .valueOutOfRange(field: .mixedDataSetPayloadByteCount, value: bytes.count)
        }
        self.init(validatedGroup: group, mdsID: mdsID, bytes: bytes)
    }

    var packet: UMPPacket {
        UMPData128Message.packet([group.value, UMPData128Message.mixedDataSetPayloadStatus << 4 | mdsID.value] + bytes)
    }
}

/// One decoded UMP Data Message (128-bit), MT 0x5.
///
/// Decoding refuses, in this order: another message type (`wrongMessageType`), a status 0x4...0x7 or 0xA...0xF
/// (`reservedStatus`); then, for SysEx8 only, a number of bytes 0 or 15 (`valueOutOfRange(field: .sysEx8ByteCount)`)
/// and any non-zero bit past the count (`reservedBitsSet`). Mixed Data Set packets use every bit, so they have no
/// further refusals. So a decoded packet always re-encodes to the received words. This type is a stateless codec; it
/// does not assemble messages or Mixed Data Sets across packets.
///
/// A number of bytes of 15 is refused for every status, as bl-midi2-rs `ValidPacketSizes` does; bl-midi2-rs
/// `sysex8::Packet` alone reads an End packet with 15 and zero data as an "unexpected end, data invalid" marker.
/// An End packet with number of bytes 1 (Stream ID only) decodes as an ordinary `end` with no data bytes.
enum UMPData128Message: Equatable, Sendable {
    case sysEx8(UMPSysEx8Packet)
    case mixedDataSetHeader(UMPMixedDataSetHeader)
    case mixedDataSetPayload(UMPMixedDataSetPayload)

    static let mixedDataSetHeaderStatus: UInt8 = 0x8
    static let mixedDataSetPayloadStatus: UInt8 = 0x9
    fileprivate static let packetByteCount = 16

    init(decoding packet: UMPPacket) throws(UMPRefusal) {
        guard packet.messageType == .data128 else {
            throw .wrongMessageType(expected: .data128, actual: packet.messageType)
        }
        let slots = packet.words.flatMap { word in
            [word >> 24, word >> 16, word >> 8, word].map { UInt8(truncatingIfNeeded: $0) }
        }
        // The group nibble is four bits, so it is always in range; so is the MDS ID nibble.
        let group = try UMPGroup(slots[0] & 0x0F)
        let statusNibble = slots[1] >> 4
        let low = slots[1] & 0x0F
        if let status = UMPSysEx8Status(rawValue: statusNibble) {
            let count = Int(low)
            guard (1...UMPSysEx8Packet.maximumByteCount + 1).contains(count) else {
                throw .valueOutOfRange(field: .sysEx8ByteCount, value: count)
            }
            let data = slots[3...]
            guard data.dropFirst(count - 1).allSatisfy({ $0 == 0 }) else {
                throw .reservedBitsSet(mt: .data128, status: statusNibble)
            }
            self = .sysEx8(UMPSysEx8Packet(
                validatedGroup: group, status: status, streamID: slots[2], bytes: Array(data.prefix(count - 1))
            ))
        } else if statusNibble == Self.mixedDataSetHeaderStatus {
            let fields = stride(from: 2, to: Self.packetByteCount, by: 2).map {
                UInt16(slots[$0]) << 8 | UInt16(slots[$0 + 1])
            }
            self = .mixedDataSetHeader(UMPMixedDataSetHeader(
                group: group, mdsID: try UMPMixedDataSetID(low), validByteCount: fields[0], chunkCount: fields[1],
                chunkNumber: fields[2], manufacturerID: fields[3], deviceID: fields[4], subID1: fields[5],
                subID2: fields[6]
            ))
        } else if statusNibble == Self.mixedDataSetPayloadStatus {
            self = .mixedDataSetPayload(UMPMixedDataSetPayload(
                validatedGroup: group, mdsID: try UMPMixedDataSetID(low), bytes: Array(slots[2...])
            ))
        } else {
            throw .reservedStatus(mt: .data128, status: statusNibble)
        }
    }

    var packet: UMPPacket {
        switch self {
        case .sysEx8(let message):
            return message.packet
        case .mixedDataSetHeader(let message):
            return message.packet
        case .mixedDataSetPayload(let message):
            return message.packet
        }
    }

    /// Packs sixteen bytes, most significant first, into an MT 0x5 packet.
    fileprivate static func packet(_ slots: [UInt8]) -> UMPPacket {
        let words = stride(from: 0, to: packetByteCount, by: 4).map { start in
            slots[start..<(start + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        return .data128(words[0], words[1], words[2], words[3])
    }
}
