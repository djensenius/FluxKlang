/// An MPE zone. The lower zone's manager is channel 1 and its members count up from channel 2; the upper zone's
/// manager is channel 16 and its members count down from channel 15. Channels are 1-based (1...16), as in
/// `MIDI1Semantic`.
enum MPEZone: Equatable, Sendable, CaseIterable {
    case lower
    case upper
}

/// The one role a channel 1...16 has under a zone configuration.
enum MPEChannelRole: Equatable, Sendable {
    /// Messages on a manager channel are zone-wide.
    case manager(MPEZone)
    /// Messages on a member channel belong to the one note bound to it.
    case member(MPEZone)
    case unassigned
}

/// Every typed refusal of the MPE zone model. A refusal always leaves the refusing value unchanged.
enum MPERefusal: Error, Equatable, Sendable {
    /// A channel outside 1...16.
    case invalidChannel(UInt8)
    /// RPN 6 arrived on a channel other than the manager channels 1 and 16.
    case notManagerChannel(UInt8)
    /// A member count outside 0...15 (the RPN 6 data entry MSB reports its own value).
    case invalidMemberCount(Int)
    /// Both zones on need two managers, so together they hold at most 14 members.
    case zonesOverlap(lowerMembers: Int, upperMembers: Int)
    /// A bend range outside 1...96 semitones.
    case invalidBendRange(Int)
    /// A note outside 0...127.
    case invalidNote(UInt8)
    /// A data value above the 7-bit (or 14-bit pitch bend) range.
    case valueOutOfRange(UInt16)
    /// The zone has no member channels.
    case zoneOff(MPEZone)
    /// Every member of the zone holds a note; nothing is stolen.
    case membersExhausted(MPEZone)
    /// The channel is not a member channel of any zone.
    case notMemberChannel(UInt8)
    /// The member channel already carries a note.
    case channelAlreadyBound(UInt8)
    /// The note is already bound to a member channel of the same zone.
    case noteAlreadyBound(UInt8)
    /// A per-note message arrived on a channel with no bound note, or on an unassigned channel.
    case unboundChannel(UInt8)
    /// The message is not channel pressure, pitch bend or controller 74.
    case notExpressionMessage
}
