import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// MPE zone model: configuration, channel roles, the member allocator and per-note expression.
/// Root file: shared fixtures plus the configuration and channel-role tests. RPN 6 lives in `+Config`, the allocator in
/// `+Allocator` and expression in `+Expression`.
#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct MPEZoneTests {
    static func config(_ lower: Int, _ upper: Int) throws -> MPEZoneConfiguration {
        try MPEZoneConfiguration.make(lowerMembers: lower, upperMembers: upper)
    }

    static func allocator(_ lower: Int, _ upper: Int) throws -> MPEMemberAllocator {
        try MPEMemberAllocator.make(configuration: config(lower, upper))
    }

    static func expression(_ lower: Int, _ upper: Int, range: Int = 48) throws -> MPENoteExpression {
        try MPENoteExpression.make(configuration: config(lower, upper), bendRange: range)
    }

    /// Mutating calls cannot sit inside `#expect` operands, so these wrappers take the state as `inout`.
    static func take(_ made: inout MPEMemberAllocator, _ note: UInt8, _ zone: MPEZone) throws -> UInt8 {
        try made.allocate(note: note, zone: zone)
    }

    static func free(_ made: inout MPEMemberAllocator, _ note: UInt8, _ zone: MPEZone) -> Bool {
        made.release(note: note, zone: zone)
    }

    static func send(_ made: inout MPENoteExpression, _ message: MIDI1Semantic) throws -> MPEExpressionUpdate {
        try made.apply(message)
    }

    static func unbound(_ made: inout MPENoteExpression, _ channel: UInt8) -> UInt8? {
        made.unbind(channel: channel)
    }

    /// Every valid (lower, upper) pair, in ascending order, built through the factory.
    static func allValidPairs() -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for lower in 0...15 {
            for upper in 0...15 where lower == 0 || upper == 0 || lower + upper <= 14 {
                pairs.append((lower, upper))
            }
        }
        #expect(pairs.count == 122)
        return pairs
    }

    @Test func aZoneAcceptsZeroToFifteenMembersAndRefusesSixteenAndNegatives() throws {
        for count in [0, 1, 14, 15] {
            let lowerOnly = try Self.config(count, 0)
            #expect(lowerOnly.lowerMembers == count)
            #expect(lowerOnly.upperMembers == 0)
            let upperOnly = try Self.config(0, count)
            #expect(upperOnly.lowerMembers == 0)
            #expect(upperOnly.upperMembers == count)
        }
        #expect(throws: MPERefusal.invalidMemberCount(16)) { try Self.config(16, 0) }
        #expect(throws: MPERefusal.invalidMemberCount(16)) { try Self.config(0, 16) }
        #expect(throws: MPERefusal.invalidMemberCount(-1)) { try Self.config(-1, 0) }
        #expect(throws: MPERefusal.invalidMemberCount(-3)) { try Self.config(0, -3) }
    }

    @Test func twoZonesHoldFourteenMembersTogetherAndFifteenOverlap() throws {
        for (lower, upper) in [(7, 7), (1, 13), (13, 1), (14, 0)] {
            let accepted = try Self.config(lower, upper)
            #expect(accepted.lowerMembers == lower)
            #expect(accepted.upperMembers == upper)
        }
        #expect(throws: MPERefusal.zonesOverlap(lowerMembers: 7, upperMembers: 8)) { try Self.config(7, 8) }
        #expect(throws: MPERefusal.zonesOverlap(lowerMembers: 1, upperMembers: 14)) { try Self.config(1, 14) }
        #expect(throws: MPERefusal.zonesOverlap(lowerMembers: 14, upperMembers: 1)) { try Self.config(14, 1) }
        #expect(throws: MPERefusal.zonesOverlap(lowerMembers: 15, upperMembers: 15)) { try Self.config(15, 15) }
    }

    @Test func aSingleZoneMayUseFifteenMembersAndEveryChannelThenHasOneRole() throws {
        let lowerOnly = try Self.config(15, 0)
        #expect(lowerOnly.memberChannels(of: .lower) == Array(UInt8(2)...16))
        let upperOnly = try Self.config(0, 15)
        #expect(upperOnly.memberChannels(of: .upper) == Array(stride(from: UInt8(15), through: 1, by: -1)))
        #expect(try MPEChannelClassifier.role(of: 16, in: lowerOnly) == .member(.lower))
        #expect(try MPEChannelClassifier.role(of: 1, in: upperOnly) == .member(.upper))
        #expect(try MPEChannelClassifier.role(of: 1, in: lowerOnly) == .manager(.lower))
        #expect(try MPEChannelClassifier.role(of: 16, in: upperOnly) == .manager(.upper))
    }

    @Test func invalidCountsAreReportedLowerFirstAndBeforeAnOverlap() throws {
        #expect(throws: MPERefusal.invalidMemberCount(16)) { try Self.config(16, -1) }
        #expect(throws: MPERefusal.invalidMemberCount(-1)) { try Self.config(-1, 16) }
        #expect(throws: MPERefusal.invalidMemberCount(20)) { try Self.config(15, 20) }
        #expect(throws: MPERefusal.invalidMemberCount(17)) { try Self.config(17, 15) }
    }

    @Test func memberChannelsRunUpFromTwoForLowerAndDownFromFifteenForUpper() throws {
        let both = try Self.config(3, 2)
        #expect(both.memberChannels(of: .lower) == [2, 3, 4])
        #expect(both.memberChannels(of: .upper) == [15, 14])
        #expect(both.managerChannel(of: .lower) == 1)
        #expect(both.managerChannel(of: .upper) == 16)
        #expect(both.memberCount(.lower) == 3)
        #expect(both.memberCount(.upper) == 2)
        let off = try Self.config(0, 0)
        #expect(off.memberChannels(of: .lower).isEmpty)
        #expect(off.memberChannels(of: .upper).isEmpty)
        #expect(off.managerChannel(of: .lower) == nil)
        #expect(off.managerChannel(of: .upper) == nil)
    }

    @Test func channelRolesWithBothZonesOnCoverEveryChannel() throws {
        let both = try Self.config(3, 2)
        var roles: [MPEChannelRole] = []
        for channel in UInt8(1)...16 { roles.append(try MPEChannelClassifier.role(of: channel, in: both)) }
        let expected: [MPEChannelRole] = [.manager(.lower)] + Array(repeating: .member(.lower), count: 3)
            + Array(repeating: .unassigned, count: 9) + Array(repeating: .member(.upper), count: 2)
            + [.manager(.upper)]
        #expect(roles == expected)
    }

    @Test func channelRolesWithOneZoneOnLeaveTheOffZoneManagerChannelUnassigned() throws {
        let lowerOnly = try Self.config(3, 0)
        #expect(try MPEChannelClassifier.role(of: 1, in: lowerOnly) == .manager(.lower))
        #expect(try MPEChannelClassifier.role(of: 4, in: lowerOnly) == .member(.lower))
        #expect(try MPEChannelClassifier.role(of: 5, in: lowerOnly) == .unassigned)
        #expect(try MPEChannelClassifier.role(of: 16, in: lowerOnly) == .unassigned)
        let upperOnly = try Self.config(0, 4)
        #expect(try MPEChannelClassifier.role(of: 1, in: upperOnly) == .unassigned)
        #expect(try MPEChannelClassifier.role(of: 16, in: upperOnly) == .manager(.upper))
        #expect(try MPEChannelClassifier.role(of: 12, in: upperOnly) == .member(.upper))
        #expect(try MPEChannelClassifier.role(of: 11, in: upperOnly) == .unassigned)
        let off = try Self.config(0, 0)
        for channel in UInt8(1)...16 { #expect(try MPEChannelClassifier.role(of: channel, in: off) == .unassigned) }
    }

    @Test func channelZeroSeventeenAndTwoFiftyFiveAreRefusedAsInvalidChannels() throws {
        let both = try Self.config(3, 2)
        for channel in [UInt8(0), 17, 255] {
            #expect(throws: MPERefusal.invalidChannel(channel)) { try MPEChannelClassifier.role(of: channel, in: both) }
        }
    }

    @Test func everyValidConfigurationGivesEachChannelExactlyOneRoleWithMatchingCounts() throws {
        for (lower, upper) in Self.allValidPairs() {
            let configuration = try Self.config(lower, upper)
            var managers: [MPEZone: Int] = [:]
            var members: [MPEZone: Int] = [:]
            for channel in UInt8(1)...16 {
                switch try MPEChannelClassifier.role(of: channel, in: configuration) {
                case let .manager(zone): managers[zone, default: 0] += 1
                case let .member(zone): members[zone, default: 0] += 1
                case .unassigned: break
                }
            }
            #expect(members[.lower, default: 0] == lower)
            #expect(members[.upper, default: 0] == upper)
            #expect(managers[.lower, default: 0] == (lower > 0 ? 1 : 0))
            #expect(managers[.upper, default: 0] == (upper > 0 ? 1 : 0))
        }
    }
}
