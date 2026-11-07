/// What a reconfiguration changed in the zone it was not asked to change: the other zone was reduced so that both
/// zones fit. A reconfiguration never shrinks a zone without reporting it here.
struct MPEZoneAdjustment: Equatable, Sendable {
    let zone: MPEZone
    let previousMembers: Int
    let resultingMembers: Int
}

/// The outcome of an RPN 6 reconfiguration: the new configuration and, when the other zone had to shrink, how.
struct MPEZoneChange: Equatable, Sendable {
    let configuration: MPEZoneConfiguration
    let adjustment: MPEZoneAdjustment?
}

/// A validated MPE zone layout. `lowerMembers` and `upperMembers` are each 0...15 (0 turns the zone off); with both
/// zones on they need two managers, so together they hold at most 14 members. Only `make` and `fromRPN6` build one
/// and the fields are read-only, so no value outside those limits exists.
struct MPEZoneConfiguration: Equatable, Sendable {
    static let maximumMembersPerZone = 15
    static let maximumMembersWithBothZones = 14
    /// The MPE specification's default member pitch bend range in semitones. It is a constant for callers to pass;
    /// `MPENoteExpression` never falls back to it.
    static let specificationDefaultBendRange = 48

    private(set) var lowerMembers: Int
    private(set) var upperMembers: Int

    private init(lowerMembers: Int, upperMembers: Int) {
        self.lowerMembers = lowerMembers
        self.upperMembers = upperMembers
    }

    /// Refuses a member count outside 0...15 (lower first), then two zones that do not fit.
    static func make(lowerMembers: Int, upperMembers: Int) throws(MPERefusal) -> MPEZoneConfiguration {
        for count in [lowerMembers, upperMembers] where !(0...maximumMembersPerZone).contains(count) {
            throw .invalidMemberCount(count)
        }
        if lowerMembers > 0, upperMembers > 0, lowerMembers + upperMembers > maximumMembersWithBothZones {
            throw .zonesOverlap(lowerMembers: lowerMembers, upperMembers: upperMembers)
        }
        return MPEZoneConfiguration(lowerMembers: lowerMembers, upperMembers: upperMembers)
    }

    /// Applies one RPN 6 message. Refuses, in this order: a channel outside 1...16, a channel that is not a manager
    /// (1 or 16), then a data entry MSB above 15. Channel 1 sets the lower zone, channel 16 the upper zone. When the
    /// other zone no longer fits it is reduced to `14 - requested` members (0 if that is negative) and the change
    /// reports the reduction.
    static func fromRPN6(
        channel: UInt8, dataEntryMSB: UInt8, current: MPEZoneConfiguration
    ) throws(MPERefusal) -> MPEZoneChange {
        guard (1...16).contains(channel) else { throw .invalidChannel(channel) }
        guard channel == 1 || channel == 16 else { throw .notManagerChannel(channel) }
        guard Int(dataEntryMSB) <= maximumMembersPerZone else { throw .invalidMemberCount(Int(dataEntryMSB)) }
        let requested = Int(dataEntryMSB)
        let zone: MPEZone = channel == 1 ? .lower : .upper
        let other: MPEZone = zone == .lower ? .upper : .lower
        let otherBefore = current.memberCount(other)
        var otherAfter = otherBefore
        if requested > 0, otherBefore > 0, requested + otherBefore > maximumMembersWithBothZones {
            otherAfter = max(0, maximumMembersWithBothZones - requested)
        }
        let lower = zone == .lower ? requested : otherAfter
        let upper = zone == .upper ? requested : otherAfter
        let configuration = try make(lowerMembers: lower, upperMembers: upper)
        let adjustment = otherAfter == otherBefore
            ? nil
            : MPEZoneAdjustment(zone: other, previousMembers: otherBefore, resultingMembers: otherAfter)
        return MPEZoneChange(configuration: configuration, adjustment: adjustment)
    }

    func memberCount(_ zone: MPEZone) -> Int {
        zone == .lower ? lowerMembers : upperMembers
    }

    /// The zone's manager channel (1 for lower, 16 for upper), or nil when the zone is off.
    func managerChannel(of zone: MPEZone) -> UInt8? {
        guard memberCount(zone) > 0 else { return nil }
        return zone == .lower ? 1 : 16
    }

    /// The zone's member channels in allocation order: 2, 3, ... for lower, 15, 14, ... for upper.
    func memberChannels(of zone: MPEZone) -> [UInt8] {
        let count = memberCount(zone)
        guard count > 0 else { return [] }
        return (0..<count).map { zone == .lower ? UInt8(2 + $0) : UInt8(15 - $0) }
    }
}
