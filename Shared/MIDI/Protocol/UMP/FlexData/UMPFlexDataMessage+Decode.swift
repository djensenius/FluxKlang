extension UMPFlexDataMessage {
    /// Decodes one Flex Data packet. Order of refusals: not MT 0xD, unknown status bank or status, form other than
    /// complete, reserved address, channel address for Set Tempo or Set Time Signature, reserved bits (including a
    /// non-zero channel nibble when group-addressed), tonic 8...15.
    init(decoding packet: UMPPacket) throws(UMPFlexDataRefusal) {
        guard packet.messageType == .flexData else { throw .notFlexData(actual: packet.messageType) }
        let words = packet.words
        let first = words[0]
        let bank = UInt8((first >> 8) & 0xFF)
        let status = UInt8(first & 0xFF)
        guard bank == Self.setupAndPerformanceBank, UMPFlexDataContent.decodedStatuses.contains(status) else {
            throw .unknownStatus(bank: bank, status: status)
        }
        let format = UInt8((first >> 22) & 0x3)
        guard format == 0 else { throw .wrongFormat(status: status, format: format) }
        let address = try Self.decodeAddress(first, status: status)
        let content: UMPFlexDataContent
        switch status {
        case UMPFlexDataContent.tempoStatus:
            try Self.requireZero(words[2] != 0 || words[3] != 0, status)
            content = .setTempo(tenNanosecondsPerQuarterNote: words[1])
        case UMPFlexDataContent.timeSignatureStatus:
            try Self.requireZero(words[1] & 0xFF != 0 || words[2] != 0 || words[3] != 0, status)
            content = .setTimeSignature(UMPFlexDataTimeSignature(
                numerator: UInt8(words[1] >> 24),
                denominatorExponent: UInt8((words[1] >> 16) & 0xFF),
                thirtySecondNotes: UInt8((words[1] >> 8) & 0xFF)
            ))
        default:
            try Self.requireZero(words[2] != 0 || words[3] != 0, status)
            content = .setKeySignature(try UMPFlexDataKeySignature(word1: words[1]))
        }
        let group: UMPGroup
        do {
            group = try UMPGroup(UInt8((first >> 24) & 0x0F))
        } catch {
            throw .ump(error)
        }
        try self.init(group: group, address: address, content: content)
    }

    private static func decodeAddress(_ first: UInt32, status: UInt8) throws(UMPFlexDataRefusal) -> UMPFlexDataAddress {
        let addressBits = UInt8((first >> 20) & 0x3)
        let channelBits = UInt8((first >> 16) & 0x0F)
        switch addressBits {
        case 0:
            guard UMPFlexDataContent.allowsChannelAddress(status: status) else {
                throw .channelAddressNotAllowed(status: status)
            }
            do {
                return .channel(try UMPChannel(channelBits))
            } catch {
                throw .ump(error)
            }
        case 1:
            // Strict: ni-midi2 calls the channel "ignored" here, and M2-104-UM was not checked. Capture keeps raw
            // MT 0xD words, so nothing is lost; #112 may want a lenient decode.
            try requireZero(channelBits != 0, status)
            return .group
        default:
            throw .reservedAddress(status: status, address: addressBits)
        }
    }

    private static func requireZero(_ reserved: Bool, _ status: UInt8) throws(UMPFlexDataRefusal) {
        if reserved { throw .reservedBitsSet(status: status) }
    }
}
