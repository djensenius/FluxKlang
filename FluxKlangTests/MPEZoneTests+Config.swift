import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MPEZoneTests {
    @Test func rpnSixSetsTheLowerZoneOnChannelOneAndTheUpperZoneOnChannelSixteen() throws {
        let first = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 5, current: Self.config(0, 0))
        #expect(first.configuration == (try Self.config(5, 0)))
        #expect(first.adjustment == nil)
        let second = try MPEZoneConfiguration.fromRPN6(channel: 16, dataEntryMSB: 3, current: first.configuration)
        #expect(second.configuration == (try Self.config(5, 3)))
        #expect(second.adjustment == nil)
    }

    @Test func rpnSixDataEntryFifteenIsAcceptedAndSixteenAndAboveAreRefused() throws {
        let fifteen = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 15, current: Self.config(0, 0))
        #expect(fifteen.configuration == (try Self.config(15, 0)))
        let upper = try MPEZoneConfiguration.fromRPN6(channel: 16, dataEntryMSB: 15, current: Self.config(0, 0))
        #expect(upper.configuration == (try Self.config(0, 15)))
        for value in [UInt8(16), 17, 127, 255] {
            let expected = MPERefusal.invalidMemberCount(Int(value))
            #expect(throws: expected) {
                try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: value, current: Self.config(0, 0))
            }
        }
    }

    @Test func rpnSixOnAnyChannelOtherThanOneOrSixteenIsRefusedAsNotManager() throws {
        let current = try Self.config(2, 2)
        for channel in UInt8(2)...15 {
            #expect(throws: MPERefusal.notManagerChannel(channel)) {
                try MPEZoneConfiguration.fromRPN6(channel: channel, dataEntryMSB: 3, current: current)
            }
        }
        for channel in [UInt8(0), 17, 255] {
            #expect(throws: MPERefusal.invalidChannel(channel)) {
                try MPEZoneConfiguration.fromRPN6(channel: channel, dataEntryMSB: 3, current: current)
            }
        }
    }

    @Test func rpnSixRefusalOrderIsChannelRangeThenManagerThenCount() throws {
        let current = try Self.config(2, 2)
        #expect(throws: MPERefusal.invalidChannel(0)) {
            try MPEZoneConfiguration.fromRPN6(channel: 0, dataEntryMSB: 16, current: current)
        }
        #expect(throws: MPERefusal.notManagerChannel(2)) {
            try MPEZoneConfiguration.fromRPN6(channel: 2, dataEntryMSB: 16, current: current)
        }
        #expect(throws: MPERefusal.invalidMemberCount(16)) {
            try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 16, current: current)
        }
    }

    @Test func reconfiguringOneZoneShrinksTheOtherAndReportsTheAdjustment() throws {
        let fits = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 9, current: Self.config(3, 5))
        #expect(fits.configuration == (try Self.config(9, 5)))
        #expect(fits.adjustment == nil)
        let overlap = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 10, current: Self.config(3, 5))
        #expect(overlap.configuration == (try Self.config(10, 4)))
        #expect(overlap.adjustment == MPEZoneAdjustment(zone: .upper, previousMembers: 5, resultingMembers: 4))
        let upper = try MPEZoneConfiguration.fromRPN6(channel: 16, dataEntryMSB: 12, current: Self.config(3, 5))
        #expect(upper.configuration == (try Self.config(2, 12)))
        #expect(upper.adjustment == MPEZoneAdjustment(zone: .lower, previousMembers: 3, resultingMembers: 2))
    }

    @Test func aRequestThatLeavesNoRoomTurnsTheOtherZoneOffAndSaysSo() throws {
        let full = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 15, current: Self.config(3, 5))
        #expect(full.configuration == (try Self.config(15, 0)))
        #expect(full.adjustment == MPEZoneAdjustment(zone: .upper, previousMembers: 5, resultingMembers: 0))
        let fourteen = try MPEZoneConfiguration.fromRPN6(channel: 16, dataEntryMSB: 14, current: Self.config(3, 5))
        #expect(fourteen.configuration == (try Self.config(0, 14)))
        #expect(fourteen.adjustment == MPEZoneAdjustment(zone: .lower, previousMembers: 3, resultingMembers: 0))
    }

    @Test func turningAZoneOffOrRequestingAgainstAnOffZoneNeverReportsAnAdjustment() throws {
        let off = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 0, current: Self.config(3, 5))
        #expect(off.configuration == (try Self.config(0, 5)))
        #expect(off.adjustment == nil)
        let single = try MPEZoneConfiguration.fromRPN6(channel: 16, dataEntryMSB: 15, current: Self.config(0, 0))
        #expect(single.configuration == (try Self.config(0, 15)))
        #expect(single.adjustment == nil)
        let against = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 15, current: Self.config(0, 0))
        #expect(against.adjustment == nil)
    }

    @Test func everyRPNSixResultIsValidKeepsTheRequestAndShrinksTheOtherZoneOnlyAsFarAsNeeded() throws {
        for (lower, upper) in Self.allValidPairs() {
            let current = try Self.config(lower, upper)
            for (channel, zone) in [(UInt8(1), MPEZone.lower), (16, .upper)] {
                for msb in UInt8(0)...15 {
                    let change = try MPEZoneConfiguration.fromRPN6(
                        channel: channel, dataEntryMSB: msb, current: current
                    )
                    let result = change.configuration
                    let otherBefore = current.memberCount(zone == .lower ? .upper : .lower)
                    let otherAfter = result.memberCount(zone == .lower ? .upper : .lower)
                    #expect(result.memberCount(zone) == Int(msb))
                    #expect(otherAfter <= otherBefore)
                    #expect((change.adjustment == nil) == (otherAfter == otherBefore))
                    if let adjustment = change.adjustment {
                        #expect(adjustment.previousMembers == otherBefore)
                        #expect(adjustment.resultingMembers == otherAfter)
                        #expect(adjustment.zone != zone)
                        let larger = zone == .lower ? (Int(msb), otherAfter + 1) : (otherAfter + 1, Int(msb))
                        #expect(throws: MPERefusal.self) { try Self.config(larger.0, larger.1) }
                    }
                }
            }
        }
    }
}
