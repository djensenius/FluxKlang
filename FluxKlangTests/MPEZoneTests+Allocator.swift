import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MPEZoneTests {
    /// An allocator built by allocating `lowerNotes` then `upperNotes`; used as an independent twin of live state.
    static func filled(
        _ lower: Int, _ upper: Int, lowerNotes: [UInt8] = [], upperNotes: [UInt8] = []
    ) throws -> MPEMemberAllocator {
        var made = try allocator(lower, upper)
        for note in lowerNotes { _ = try made.allocate(note: note, zone: .lower) }
        for note in upperNotes { _ = try made.allocate(note: note, zone: .upper) }
        return made
    }

    @Test func membersHoldThatManyNotesAndTheNextNoteIsRefusedWithNothingStolen() throws {
        var live = try Self.filled(3, 0, lowerNotes: [60, 61, 62])
        #expect(live.heldCount(in: .lower) == 3)
        #expect(throws: MPERefusal.membersExhausted(.lower)) { try live.allocate(note: 63, zone: .lower) }
        #expect(live == (try Self.filled(3, 0, lowerNotes: [60, 61, 62])))
        #expect(live.note(on: 2) == 60)
        #expect(live.note(on: 3) == 61)
        #expect(live.note(on: 4) == 62)
    }

    @Test func aZoneOfOneMemberAcceptsOneNoteAndRefusesTheSecond() throws {
        var live = try Self.filled(0, 1, upperNotes: [40])
        #expect(throws: MPERefusal.membersExhausted(.upper)) { try live.allocate(note: 41, zone: .upper) }
        #expect(live == (try Self.filled(0, 1, upperNotes: [40])))
        var fifteen = try Self.allocator(15, 0)
        for note in UInt8(0)..<15 { #expect(try Self.take(&fifteen, note, .lower) == note + 2) }
        #expect(throws: MPERefusal.membersExhausted(.lower)) { try fifteen.allocate(note: 99, zone: .lower) }
        #expect(fifteen == (try Self.filled(15, 0, lowerNotes: Array(0..<15))))
    }

    @Test func theFirstAllocationTakesTheLowestMemberAndEachNextOneTheNextMember() throws {
        var live = try Self.allocator(3, 3)
        #expect(try Self.take(&live, 60, .lower) == 2)
        #expect(try Self.take(&live, 60, .upper) == 15)
        #expect(try Self.take(&live, 61, .lower) == 3)
        #expect(try Self.take(&live, 61, .upper) == 14)
        #expect(try Self.take(&live, 62, .lower) == 4)
        #expect(try Self.take(&live, 62, .upper) == 13)
        #expect(live.heldCount(in: .lower) == 3)
        #expect(live.heldCount(in: .upper) == 3)
        #expect(live.note(on: 2) == 60)
        #expect(live.note(on: 13) == 62)
        #expect(live.channel(of: 61, in: .lower) == 3)
    }

    @Test func aReleasedChannelIsReusedOnlyWhenTheRoundRobinCursorWrapsToIt() throws {
        var live = try Self.allocator(4, 0)
        #expect(try Self.take(&live, 60, .lower) == 2)
        #expect(try Self.take(&live, 61, .lower) == 3)
        #expect(Self.free(&live, 61, .lower))
        #expect(try Self.take(&live, 62, .lower) == 4)
        #expect(try Self.take(&live, 63, .lower) == 5)
        #expect(try Self.take(&live, 64, .lower) == 3)
        #expect(throws: MPERefusal.membersExhausted(.lower)) { try live.allocate(note: 65, zone: .lower) }
    }

    @Test func aFullZoneAcceptsANoteAgainAfterOneReleaseOnTheFreedChannel() throws {
        var live = try Self.filled(3, 0, lowerNotes: [60, 61, 62])
        #expect(Self.free(&live, 61, .lower))
        #expect(live.heldCount(in: .lower) == 2)
        #expect(live.note(on: 3) == nil)
        #expect(try Self.take(&live, 70, .lower) == 3)
        #expect(live.note(on: 3) == 70)
    }

    @Test func allocatingAHeldNoteAgainReturnsItsChannelAndChangesNothing() throws {
        var live = try Self.filled(3, 2, lowerNotes: [60, 61], upperNotes: [60])
        #expect(try Self.take(&live, 61, .lower) == 3)
        #expect(try Self.take(&live, 60, .upper) == 15)
        #expect(live == (try Self.filled(3, 2, lowerNotes: [60, 61], upperNotes: [60])))
        #expect(try Self.take(&live, 62, .lower) == 4)
    }

    @Test func releasingAnUnknownNoteIsANoOpReturningFalse() throws {
        var live = try Self.filled(3, 2, lowerNotes: [60], upperNotes: [61])
        #expect(!Self.free(&live, 99, .lower))
        #expect(!Self.free(&live, 61, .lower))
        #expect(!Self.free(&live, 60, .upper))
        #expect(!Self.free(&live, 200, .lower))
        #expect(live == (try Self.filled(3, 2, lowerNotes: [60], upperNotes: [61])))
        #expect(Self.free(&live, 60, .lower))
        #expect(!Self.free(&live, 60, .lower))
        var twin = try Self.filled(3, 2, lowerNotes: [60], upperNotes: [61])
        twin.release(note: 60, zone: .lower)
        #expect(live == twin)
    }

    @Test func theOrderOfReleasesDoesNotChangeWhichChannelsAreFree() throws {
        var forward = try Self.filled(4, 0, lowerNotes: [60, 61, 62, 63])
        var backward = forward
        #expect(Self.free(&forward, 61, .lower))
        #expect(Self.free(&forward, 63, .lower))
        #expect(Self.free(&backward, 63, .lower))
        #expect(Self.free(&backward, 61, .lower))
        #expect(forward == backward)
        #expect(forward.note(on: 3) == nil)
        #expect(forward.note(on: 5) == nil)
        #expect(forward.note(on: 2) == 60)
        #expect(forward.note(on: 4) == 62)
    }

    @Test func aNoteAbove127IsRefusedAndAZoneThatIsOffRefusesAndTheNoteCheckComesFirst() throws {
        var live = try Self.allocator(3, 0)
        #expect(try Self.take(&live, 127, .lower) == 2)
        #expect(try Self.take(&live, 0, .lower) == 3)
        #expect(throws: MPERefusal.invalidNote(128)) { try live.allocate(note: 128, zone: .lower) }
        #expect(throws: MPERefusal.zoneOff(.upper)) { try live.allocate(note: 60, zone: .upper) }
        #expect(throws: MPERefusal.invalidNote(200)) { try live.allocate(note: 200, zone: .upper) }
        #expect(live == (try Self.filled(3, 0, lowerNotes: [127, 0])))
    }

    @Test func theSameNoteInTheTwoZonesHoldsTwoChannelsAndReleasesIndependently() throws {
        var live = try Self.filled(2, 2, lowerNotes: [60], upperNotes: [60])
        #expect(live.channel(of: 60, in: .lower) == 2)
        #expect(live.channel(of: 60, in: .upper) == 15)
        #expect(Self.free(&live, 60, .lower))
        #expect(live.channel(of: 60, in: .lower) == nil)
        #expect(live.channel(of: 60, in: .upper) == 15)
    }

    @Test func exhaustingOneZoneLeavesTheOtherZoneUsableWithItsOwnCursor() throws {
        var live = try Self.filled(1, 2, lowerNotes: [60])
        #expect(throws: MPERefusal.membersExhausted(.lower)) { try live.allocate(note: 61, zone: .lower) }
        #expect(try Self.take(&live, 61, .upper) == 15)
        #expect(try Self.take(&live, 62, .upper) == 14)
        #expect(throws: MPERefusal.membersExhausted(.upper)) { try live.allocate(note: 63, zone: .upper) }
        #expect(live.heldCount(in: .lower) == 1)
        #expect(live.heldCount(in: .upper) == 2)
    }

    @Test func capacityEqualsTheMemberCountAndLookupsStayInRange() throws {
        let live = try Self.filled(3, 2, lowerNotes: [60], upperNotes: [61])
        #expect(live.capacity(of: .lower) == 3)
        #expect(live.capacity(of: .upper) == 2)
        #expect(live.note(on: 1) == nil)
        #expect(live.note(on: 16) == nil)
        #expect(live.note(on: 0) == nil)
        #expect(live.note(on: 17) == nil)
        #expect(live.note(on: 2) == 60)
        #expect(live.note(on: 15) == 61)
        #expect(live.channel(of: 99, in: .lower) == nil)
    }

    static func mpxDisplaced(_ channel: UInt8, _ note: UInt8, _ zone: MPEZone) -> MPEDisplacedNote {
        MPEDisplacedNote(channel: channel, note: note, zone: zone)
    }

    @Test func displacedNotesAreEmptyWhenEveryHeldNoteStaysOnAMemberChannelOfItsZone() throws {
        let held = try Self.filled(5, 0, lowerNotes: [60, 61, 62, 63, 64])
        for (lower, upper) in [(5, 0), (6, 0), (15, 0), (5, 3)] {
            #expect(MPEZoneImpact.displacedNotes(in: held, after: try Self.config(lower, upper)).isEmpty)
        }
        let empty = try Self.filled(3, 3)
        #expect(MPEZoneImpact.displacedNotes(in: empty, after: try Self.config(0, 0)).isEmpty)
    }

    @Test func aShrinkingLowerZoneDisplacesTheNotesOnItsDroppedMembers() throws {
        let held = try Self.filled(5, 0, lowerNotes: [60, 61, 62, 63, 64])
        let report = MPEZoneImpact.displacedNotes(in: held, after: try Self.config(3, 0))
        #expect(report == [Self.mpxDisplaced(5, 63, .lower), Self.mpxDisplaced(6, 64, .lower)])
    }

    @Test func aShrinkingUpperZoneIsReportedAscendingByChannel() throws {
        let held = try Self.filled(0, 5, upperNotes: [60, 61, 62, 63, 64])
        let report = MPEZoneImpact.displacedNotes(in: held, after: try Self.config(0, 2))
        #expect(report == [
            Self.mpxDisplaced(11, 64, .upper), Self.mpxDisplaced(12, 63, .upper), Self.mpxDisplaced(13, 62, .upper)
        ])
    }

    @Test func displacedNotesCoverOnlyHeldChannelsNotFreeOnes() throws {
        var held = try Self.filled(5, 0, lowerNotes: [60, 61, 62, 63, 64])
        for note in [UInt8(61), 62, 63] { #expect(Self.free(&held, note, .lower)) }
        let report = MPEZoneImpact.displacedNotes(in: held, after: try Self.config(1, 0))
        #expect(report == [Self.mpxDisplaced(6, 64, .lower)])
    }

    @Test func turningAZoneOffDisplacesEveryHeldNoteOfThatZone() throws {
        let off = try Self.config(0, 0)
        let lowerHeld = try Self.filled(5, 0, lowerNotes: [60, 61, 62, 63, 64])
        let lowerReport = MPEZoneImpact.displacedNotes(in: lowerHeld, after: off)
        #expect(lowerReport.map(\.channel) == [2, 3, 4, 5, 6])
        #expect(lowerReport.map(\.note) == [60, 61, 62, 63, 64])
        #expect(lowerReport.allSatisfy { $0.zone == .lower })
        let upperHeld = try Self.filled(0, 3, upperNotes: [70, 71, 72])
        #expect(MPEZoneImpact.displacedNotes(in: upperHeld, after: off) == [
            Self.mpxDisplaced(13, 72, .upper), Self.mpxDisplaced(14, 71, .upper), Self.mpxDisplaced(15, 70, .upper)
        ])
        let both = try Self.filled(3, 4, lowerNotes: [10, 11, 12], upperNotes: [20, 21, 22, 23])
        #expect(MPEZoneImpact.displacedNotes(in: both, after: off) == [
            Self.mpxDisplaced(2, 10, .lower), Self.mpxDisplaced(3, 11, .lower), Self.mpxDisplaced(4, 12, .lower),
            Self.mpxDisplaced(12, 23, .upper), Self.mpxDisplaced(13, 22, .upper), Self.mpxDisplaced(14, 21, .upper),
            Self.mpxDisplaced(15, 20, .upper)
        ])
    }

    @Test func aSingleZoneShrinkingFromFifteenMembersDisplacesNotesOnTheEdgeChannels() throws {
        let lowerHeld = try Self.filled(15, 0, lowerNotes: Array(60...74))
        let lowerChange = try MPEZoneConfiguration.fromRPN6(channel: 16, dataEntryMSB: 2, current: Self.config(15, 0))
        #expect(MPEZoneImpact.displacedNotes(in: lowerHeld, after: lowerChange.configuration) == [
            Self.mpxDisplaced(14, 72, .lower), Self.mpxDisplaced(15, 73, .lower), Self.mpxDisplaced(16, 74, .lower)
        ])
        let upperHeld = try Self.filled(0, 15, upperNotes: Array(60...74))
        let upperChange = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 2, current: Self.config(0, 15))
        #expect(MPEZoneImpact.displacedNotes(in: upperHeld, after: upperChange.configuration) == [
            Self.mpxDisplaced(1, 74, .upper), Self.mpxDisplaced(2, 73, .upper), Self.mpxDisplaced(3, 72, .upper)
        ])
    }

    @Test func upperNotesOnChannelsThatBecameLowerMembersAreStillDisplaced() throws {
        let held = try Self.filled(3, 5, lowerNotes: [60, 61, 62], upperNotes: [80, 81, 82, 83, 84])
        let change = try MPEZoneConfiguration.fromRPN6(channel: 1, dataEntryMSB: 12, current: Self.config(3, 5))
        #expect(change.configuration == (try Self.config(12, 2)))
        #expect(MPEZoneImpact.displacedNotes(in: held, after: change.configuration) == [
            Self.mpxDisplaced(11, 84, .upper), Self.mpxDisplaced(12, 83, .upper), Self.mpxDisplaced(13, 82, .upper)
        ])
    }

    @Test func theSameNoteNumberInBothZonesIsReportedPerZoneInChannelOrder() throws {
        let held = try Self.filled(3, 3, lowerNotes: [60, 61, 62], upperNotes: [60, 61, 62])
        #expect(MPEZoneImpact.displacedNotes(in: held, after: try Self.config(0, 1)) == [
            Self.mpxDisplaced(2, 60, .lower), Self.mpxDisplaced(3, 61, .lower), Self.mpxDisplaced(4, 62, .lower),
            Self.mpxDisplaced(13, 62, .upper), Self.mpxDisplaced(14, 61, .upper)
        ])
    }

    @Test func reportingDisplacedNotesChangesNothingAndRepeatsTheSameAnswer() throws {
        let held = try Self.filled(3, 3, lowerNotes: [60, 61, 62], upperNotes: [70, 71])
        let twin = try Self.filled(3, 3, lowerNotes: [60, 61, 62], upperNotes: [70, 71])
        let target = try Self.config(1, 1)
        let first = MPEZoneImpact.displacedNotes(in: held, after: target)
        #expect(held == twin)
        let second = MPEZoneImpact.displacedNotes(in: held, after: target)
        #expect(held == twin)
        #expect(first.count == 3)
        #expect(first == second)
    }

    @Test func displacedNotesMatchAnIndependentOracleForEveryPairOfLayouts() throws {
        let pairs = Self.allValidPairs()
        var total = 0
        for (oldLower, oldUpper) in pairs {
            let lowerNotes = (0..<oldLower).map { UInt8(10 + $0) }
            let upperNotes = (0..<oldUpper).map { UInt8(60 + $0) }
            let held = try Self.filled(oldLower, oldUpper, lowerNotes: lowerNotes, upperNotes: upperNotes)
            for (newLower, newUpper) in pairs {
                var expected: [MPEDisplacedNote] = []
                for index in 0..<oldLower where index >= newLower {
                    expected.append(Self.mpxDisplaced(UInt8(2 + index), UInt8(10 + index), .lower))
                }
                for index in 0..<oldUpper where index >= newUpper {
                    expected.append(Self.mpxDisplaced(UInt8(15 - index), UInt8(60 + index), .upper))
                }
                expected.sort { $0.channel < $1.channel }
                let report = MPEZoneImpact.displacedNotes(in: held, after: try Self.config(newLower, newUpper))
                #expect(report == expected)
                total += 1
            }
        }
        #expect(total == 14_884)
    }

    @Test func aFreshAllocatorForAnOffConfigurationHoldsNothingAndRefusesBothZones() throws {
        var live = try Self.allocator(0, 0)
        for channel in UInt8(1)...16 { #expect(live.note(on: channel) == nil) }
        #expect(throws: MPERefusal.zoneOff(.lower)) { try live.allocate(note: 60, zone: .lower) }
        #expect(throws: MPERefusal.zoneOff(.upper)) { try live.allocate(note: 60, zone: .upper) }
        #expect(live == (try Self.allocator(0, 0)))
    }
}
