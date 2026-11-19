/// One message the stream sends, in output order: a MIDI 2.0 channel voice (MT 0x4), a passed-through System Common /
/// System Real Time message (MT 0x1), or one packet of a complete SysEx payload (MT 0x3).
enum UMPTranslationStreamItem: Equatable, Sendable {
    /// A MIDI 2.0 channel voice message, including a held Data Entry (CC 6) sent before a system or SysEx message.
    case voice(UMPMIDI2ChannelVoice)
    /// The MT 0x1 message, passed through with its group.
    case system(UMPSystemCommonRealTime)
    /// One MT 0x3 packet, with the input group; all packets of the payload are sent together.
    case sysEx7(UMPSysEx7Packet)
}
