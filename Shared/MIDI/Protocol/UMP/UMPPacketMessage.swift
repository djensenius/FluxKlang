/// One checked `UMPPacket` routed by its Message Type to the typed decoder for that type.
///
/// This is a stateless classifier: it decodes a single packet and never joins text, SysEx or Flex Data across
/// packets. Reserved Message Types (0x6...0xC except 0xD, and 0xE) have no defined messages, so they are kept whole
/// as `reserved` and never refused; a receiver skips them. `UMPPacket(words:)` has already checked the word count.
enum UMPPacketMessage: Equatable, Sendable {
    /// MT 0x0.
    case utility(UMPUtilityMessage)
    /// MT 0x1.
    case system(UMPSystemCommonRealTime)
    /// MT 0x2.
    case midi1ChannelVoice(UMPMIDI1ChannelVoice)
    /// MT 0x3.
    case sysEx7(UMPSysEx7Packet)
    /// MT 0x4.
    case midi2ChannelVoice(UMPMIDI2ChannelVoice)
    /// MT 0x5.
    case data128(UMPData128Message)
    /// MT 0xD, status bank 0x00 (tempo, time signature, key signature).
    case flexData(UMPFlexDataMessage)
    /// MT 0xD, status bank 0x01 (metadata text) or 0x02 (performance text) with a defined status.
    case flexDataText(UMPFlexDataTextPacket)
    /// MT 0xF.
    case stream(UMPStreamMessage)
    /// A reserved Message Type, with its words unchanged.
    case reserved(UMPPacket)

    /// Routes the packet by Message Type. Flex Data is split on the status bank and status of the first word:
    /// a text kind goes to `UMPFlexDataTextPacket`, everything else to `UMPFlexDataMessage`, which refuses an unknown
    /// bank or status with `unknownStatus`. `streamLimits` bounds Stream text and has no default.
    init(decoding packet: UMPPacket, streamLimits: UMPStreamLimits) throws(UMPPacketMessageRefusal) {
        switch packet.messageType {
        case .utility:
            self = .utility(try Self.wrapping { () throws(UMPRefusal) in try UMPUtilityMessage(decoding: packet) })
        case .system:
            self = .system(try Self.wrapping { () throws(UMPRefusal) in try UMPSystemCommonRealTime(decoding: packet) })
        case .midi1ChannelVoice:
            self = .midi1ChannelVoice(
                try Self.wrapping { () throws(UMPRefusal) in try UMPMIDI1ChannelVoice(decoding: packet) })
        case .data64:
            self = .sysEx7(try Self.wrapping { () throws(UMPRefusal) in try UMPSysEx7Packet(decoding: packet) })
        case .midi2ChannelVoice:
            self = .midi2ChannelVoice(
                try Self.wrapping { () throws(UMPRefusal) in try UMPMIDI2ChannelVoice(decoding: packet) })
        case .data128:
            self = .data128(try Self.wrapping { () throws(UMPRefusal) in try UMPData128Message(decoding: packet) })
        case .flexData:
            self = try Self.decodeFlexData(packet)
        case .stream:
            do {
                self = .stream(try UMPStreamMessage.decode(packet, limits: streamLimits))
            } catch {
                throw .stream(error)
            }
        case .reserved6, .reserved7, .reserved8, .reserved9, .reservedA, .reservedB, .reservedC, .reservedE:
            self = .reserved(packet)
        }
    }

    private static func wrapping<Value>(_ decode: () throws(UMPRefusal) -> Value) throws(UMPPacketMessageRefusal)
        -> Value {
        do {
            return try decode()
        } catch {
            throw .packet(error)
        }
    }

    private static func decodeFlexData(_ packet: UMPPacket) throws(UMPPacketMessageRefusal) -> UMPPacketMessage {
        let first = packet.words[0]
        let bank = UInt8((first >> 8) & 0xFF)
        let status = UInt8(first & 0xFF)
        do {
            if UMPFlexDataTextKind(bank: bank, status: status) != nil {
                return .flexDataText(try UMPFlexDataTextPacket(decoding: packet))
            }
            return .flexData(try UMPFlexDataMessage(decoding: packet))
        } catch {
            throw .flexData(error)
        }
    }
}
