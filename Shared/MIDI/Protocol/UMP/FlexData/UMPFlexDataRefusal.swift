/// The range-checked field behind `UMPFlexDataRefusal.invalidField`.
enum UMPFlexDataField: Equatable, Sendable {
    /// The signed Set Key Signature sharps/flats count, -8...7.
    case sharpsOrFlats
    /// The Set Key Signature tonic nibble; 8...15 name no note.
    case tonic
}

/// Every refusal from the Flex Data (MT 0xD) codec. A refused call returns nothing and changes nothing.
///
/// `status` values are the Setup and Performance (status bank 0x00) status byte; every refusal after
/// `unknownStatus` is only reachable for status bank 0x00.
enum UMPFlexDataRefusal: Error, Equatable, Sendable {
    /// The packet is not Message Type 0xD.
    case notFlexData(actual: UMPMessageType)
    /// The status bank and status are not a message this codec decodes. This includes the known Set Metronome
    /// (0x00/0x02) and Set Chord Name (0x00/0x06), and every text message of banks 0x01 and 0x02.
    case unknownStatus(bank: UInt8, status: UInt8)
    /// The form (word 0 bits 23...22) is not 0 (complete); these messages always fit in one packet.
    case wrongFormat(status: UInt8, format: UInt8)
    /// The address (word 0 bits 21...20) is 2 or 3, which no source defines.
    case reservedAddress(status: UInt8, address: UInt8)
    /// Building only: Set Tempo and Set Time Signature are built addressed to the whole group, never to one channel.
    /// Decoding accepts a channel address for every status and never throws this.
    case channelAddressNotAllowed(status: UInt8)
    /// A reserved bit is non-zero. The channel nibble of a group-addressed message is ignored, not refused.
    case reservedBitsSet(status: UInt8)
    /// A field is outside its allowed range or names a reserved value.
    case invalidField(UMPFlexDataField, value: Int)
    /// `UMPPacket`, `UMPGroup` or `UMPChannel` refused a value built from checked fields (unreachable through
    /// this API).
    case ump(UMPRefusal)
}
