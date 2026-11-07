/// Classifies a channel 1...16 under a zone configuration. Every channel has exactly one role.
enum MPEChannelClassifier {
    /// Refuses a channel outside 1...16 with `invalidChannel`. A manager channel is channel 1 when the lower zone is
    /// on and channel 16 when the upper zone is on; a member channel is in `memberChannels(of:)`; any other channel
    /// is unassigned (including the manager channel of a zone that is off).
    static func role(of channel: UInt8, in configuration: MPEZoneConfiguration) throws(MPERefusal) -> MPEChannelRole {
        guard (1...16).contains(channel) else { throw .invalidChannel(channel) }
        for zone in MPEZone.allCases where configuration.managerChannel(of: zone) == channel {
            return .manager(zone)
        }
        for zone in MPEZone.allCases where configuration.memberChannels(of: zone).contains(channel) {
            return .member(zone)
        }
        return .unassigned
    }
}
