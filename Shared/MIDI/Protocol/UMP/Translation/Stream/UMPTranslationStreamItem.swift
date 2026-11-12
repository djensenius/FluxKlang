/// One message `UMPTranslationStream.receive(system:at:)` sends, in output order: a MIDI 2.0 channel voice message
/// (MT 0x4, a held CC 6 flushed before the system message) or the UMP System Common / System Real Time message
/// (MT 0x1) itself, unchanged.
enum UMPTranslationStreamItem: Equatable, Sendable {
    /// A MIDI 2.0 channel voice message: a held Data Entry (CC 6) sent before the system message.
    case voice(UMPMIDI2ChannelVoice)
    /// The MT 0x1 message, passed through with its group.
    case system(UMPSystemCommonRealTime)
}
