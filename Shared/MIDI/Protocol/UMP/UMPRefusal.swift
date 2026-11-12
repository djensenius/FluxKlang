/// The field a UMP factory or scaling call checked.
enum UMPField: Equatable, Sendable {
    case group
    case channel
    case sevenBit
    case fourteenBit
    /// The 20-bit MT 0x0 Delta Clockstamp tick count.
    case twentyBit
    case scaledValue
    case batchLimit
}

// `mt` is the coordinator-ruled label for the Message Type in refusals.
// swiftlint:disable identifier_name
/// Every refusal from the UMP codec. A refused call returns nothing and changes nothing.
enum UMPRefusal: Error, Equatable, Sendable {
    /// The batch ends inside a packet whose type needs `need` words; only `have` remain. The whole batch is refused.
    case truncated(mt: UMPMessageType, have: Int, need: Int)
    /// A split call received more words than its bound allows.
    case batchTooLarge(count: Int, limit: Int)
    /// A packet was built from a word count that does not match its message type.
    case wrongWordCount(mt: UMPMessageType, have: Int, need: Int)
    /// A packet was built from no words.
    case emptyPacket
    /// A channel voice, utility or system decoder received a packet of another message type.
    case wrongMessageType(expected: UMPMessageType, actual: UMPMessageType)
    /// The status is not defined for this message type (MT0: 0x0...0x4; MT1: 0xF1...0xF3, 0xF6, 0xF8, 0xFA...0xFC,
    /// 0xFE, 0xFF; MT2: 0x80...0xEF; MT4: any nibble but 0x7).
    case reservedStatus(mt: UMPMessageType, status: UInt8)
    /// A reserved bit or field is non-zero. The status is the MT1/MT2 status byte or the MT0/MT4 status nibble.
    case reservedBitsSet(mt: UMPMessageType, status: UInt8)
    /// `MIDI1Semantic` refuses the MT2 status and data bytes.
    case invalidMIDI1Message(status: UInt8, data1: UInt8, data2: UInt8?)
    /// Only `MIDI1Event.channel` and the channel cases of `MIDI1Semantic` can be carried by MT2.
    case notChannelVoice
    /// Only `MIDI1Event.systemCommon` and `.realTime`, in the shape `MIDI1Parser` produces, can be carried by MT1.
    case notSystemMessage
    /// A value is outside the range of its field.
    case valueOutOfRange(field: UMPField, value: Int)
    /// A scaling width pair is outside 1...32 or points the wrong way.
    case invalidScale(fromBits: Int, toBits: Int)
}
// swiftlint:enable identifier_name
