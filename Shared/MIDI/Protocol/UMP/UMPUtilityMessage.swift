/// The Utility messages (MT 0x0) of M2-104-UM (UMP and MIDI 2.0 Protocol v1.1, Utility Messages): one 32-bit word,
/// `[0x0 | reserved][status | data bits 19...16][data bits 15...8][data bits 7...0]`.
///
/// MT 0x0 is groupless in UMP 1.1 (`UMPMessageType.carriesGroup`), so bits 27...24 are reserved and must be zero.
/// A UMP 1.0 sender may still put a Group there; such a packet is refused with `reservedBitsSet`, as every other
/// non-zero reserved bit is, so a decoded message always re-encodes to the received word.
///
/// Decoding refuses, in this order: another message type (`wrongMessageType`), a reserved status 0x5...0xF
/// (`reservedStatus`), then any non-zero reserved bit (`reservedBitsSet`): the group nibble, bits 19...16 of JR
/// Clock, JR Timestamp and DCTPQ, and every data bit of NOOP.
/// This type is a codec only: nothing here reads clocks or applies timestamps.
enum UMPUtilityMessage: Equatable, Sendable {
    /// Status 0x0: no data.
    case noop
    /// Status 0x1: the sender's 16-bit clock time.
    case jrClock(senderTime: UInt16)
    /// Status 0x2: the sender's 16-bit clock timestamp for the next message.
    case jrTimestamp(UInt16)
    /// Status 0x3: Delta Clockstamp Ticks Per Quarter Note.
    case deltaClockstampTicksPerQuarterNote(UInt16)
    /// Status 0x4: ticks since the last event, a 20-bit field (0...0xFFFFF); encoding refuses larger values.
    case deltaClockstamp(ticks: UInt32)

    /// The largest Delta Clockstamp tick count bits 19...0 can carry.
    static let maximumDeltaClockstampTicks: UInt32 = 0xF_FFFF

    init(decoding packet: UMPPacket) throws(UMPRefusal) {
        guard packet.messageType == .utility else {
            throw .wrongMessageType(expected: .utility, actual: packet.messageType)
        }
        let word = packet.words[0]
        let status = UInt8((word >> 20) & 0x0F)
        let data = word & 0x000F_FFFF
        let value = UInt16(truncatingIfNeeded: word)
        let reserved: UInt32
        switch status {
        case 0x0:
            reserved = data
            self = .noop
        case 0x1:
            reserved = data & 0x000F_0000
            self = .jrClock(senderTime: value)
        case 0x2:
            reserved = data & 0x000F_0000
            self = .jrTimestamp(value)
        case 0x3:
            reserved = data & 0x000F_0000
            self = .deltaClockstampTicksPerQuarterNote(value)
        case 0x4:
            reserved = 0
            self = .deltaClockstamp(ticks: data)
        default:
            throw .reservedStatus(mt: .utility, status: status)
        }
        guard word & 0x0F00_0000 == 0, reserved == 0 else { throw .reservedBitsSet(mt: .utility, status: status) }
    }

    /// The one-word packet with a zero group nibble. Refuses Delta Clockstamp ticks above 0xFFFFF.
    func packet() throws(UMPRefusal) -> UMPPacket {
        let status: UInt32
        let data: UInt32
        switch self {
        case .noop:
            (status, data) = (0x0, 0)
        case let .jrClock(senderTime):
            (status, data) = (0x1, UInt32(senderTime))
        case let .jrTimestamp(timestamp):
            (status, data) = (0x2, UInt32(timestamp))
        case let .deltaClockstampTicksPerQuarterNote(ticks):
            (status, data) = (0x3, UInt32(ticks))
        case let .deltaClockstamp(ticks):
            guard ticks <= Self.maximumDeltaClockstampTicks else {
                throw .valueOutOfRange(field: .twentyBit, value: Int(ticks))
            }
            (status, data) = (0x4, ticks)
        }
        // MT 0x0 is a one-word type, so this word count is always accepted.
        return try UMPPacket(words: [status << 20 | data])
    }
}
