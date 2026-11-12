/// Why `UMPPacketMessage` could not classify a packet: the refusal of the decoder the packet was routed to, kept whole.
///
/// Reserved Message Types are never refused (`UMPPacketMessage.reserved`), so there is no case for them.
enum UMPPacketMessageRefusal: Error, Equatable, Sendable {
    /// A Message Type 0x0...0x5 decoder refused the packet.
    case packet(UMPRefusal)
    /// A Flex Data (MT 0xD) decoder refused the packet.
    case flexData(UMPFlexDataRefusal)
    /// The Stream (MT 0xF) decoder refused the packet.
    case stream(UMPStreamRefusal)
}
