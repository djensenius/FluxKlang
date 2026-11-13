/// The MIDI 1 control changes that make up an MPE Configuration Message for one zone (#82, slice MPC1). Nothing calls
/// it yet. The layout agrees with the MPE specification (version 1.0, 2.1.1): the ordinary RPN sequence
/// (controller 101 = MSB 0, controller 100 = LSB 6, then Data Entry MSB, controller 6) on the zone's manager channel,
/// which is what `MPEZoneConfiguration.fromRPN6` and `MIDI1PerformanceState` already accept. The specification lists
/// controller 100 before 101 (the receiver here selects 0/6 in either order), and each of its examples starts with
/// Reset All Controllers (controller 121), which is not sent. No null-function terminator (101 and 100 = 127) follows,
/// as in its examples, and only the one zone is checked: a receiver shrinks the other zone when the two do not fit,
/// and `fromRPN6` reports it.
enum MPEConfigurationMessage {
    /// The three control changes of an MPE Configuration Message that sets `zone` to `members` member channels.
    /// Refuses a count outside 0...15 (0 turns the zone off) before building anything.
    static func messages(zone: MPEZone, members: Int) throws(MPERefusal) -> [MIDI1Semantic] {
        guard (0...MPEZoneConfiguration.maximumMembersPerZone).contains(members) else {
            throw .invalidMemberCount(members)
        }
        let manager: UInt8 = zone == .lower ? 1 : 16
        return [
            .controlChange(channel: manager, controller: 101, value: 0),
            .controlChange(channel: manager, controller: 100, value: 6),
            .controlChange(channel: manager, controller: 6, value: UInt8(members))
        ]
    }
}
