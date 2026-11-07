/// The limit a `UMPStreamLimits` factory call checked.
enum UMPStreamLimitField: Equatable, Sendable {
    case maximumTextBytes
}

/// The range-checked field behind `UMPStreamRefusal.invalidField`.
enum UMPStreamField: Equatable, Sendable {
    case functionBlockCount
    case midi1Mode
    case direction
    case firstGroup
    case groupCount
    case midiCIVersion
    case deviceIdentityByte
}

/// Every refusal from the UMP Stream message codec. A refused call returns nothing and changes nothing.
enum UMPStreamRefusal: Error, Equatable, Sendable {
    /// The packet is not Message Type 0xF.
    case notStream(actual: UMPMessageType)
    /// The 10-bit status is not one this codec decodes (this includes Start/End of Clip, status 0x20 and 0x21).
    case unknownStatus(UInt16)
    /// A message that has one packet, or a text message handed to `decode`, carries a format other than 0.
    case wrongFormat(status: UInt16, format: UInt8)
    /// A reserved bit of the message is non-zero.
    case reservedBitsSet(status: UInt16)
    /// A function block index is outside 0...31 (0xFF is only valid as "all" in a Function Block Discovery).
    case functionBlockOutOfRange(Int)
    /// A stream protocol other than 1 (MIDI 1.0) or 2 (MIDI 2.0).
    case invalidProtocol(UInt8)
    /// A field is outside its allowed range or names a reserved value.
    case invalidField(UMPStreamField, value: Int)
    /// The assembler was fed a Stream message that carries no text.
    case notTextStatus(UInt16)
    /// A continue or end packet arrived with no start pending.
    case orphanContinue(status: UInt16)
    /// A start or complete packet arrived while another text was being assembled.
    case unexpectedStart(pendingStatus: UInt16)
    /// A continue or end packet names another message than the pending text.
    case mismatchedStatus(expected: UInt16, actual: UInt16)
    /// A continue or end packet of a Function Block Name names another function block than the pending text.
    case mismatchedFunctionBlock(expected: Int, actual: Int)
    /// A text would use more packets than its message allows (7, 3 or 7).
    case tooManyPackets(limit: Int)
    /// A text is longer than min(`maximumTextBytes`, the message maximum); the value is the refused byte count.
    case textTooLong(Int)
    /// The finished text bytes are not strict UTF-8.
    case invalidUTF8
    /// A text ends in a zero byte, which the zero padding of the wire format cannot carry.
    case trailingZeroByte
    /// A limits factory argument is outside its range.
    case invalidLimit(UMPStreamLimitField, value: Int)
    /// `UMPPacket.init(words:)` refused the words of an encoded packet (unreachable through this API).
    case packet(UMPRefusal)
}
