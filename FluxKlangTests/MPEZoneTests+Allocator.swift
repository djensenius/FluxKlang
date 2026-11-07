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

    @Test func aFreshAllocatorForAnOffConfigurationHoldsNothingAndRefusesBothZones() throws {
        var live = try Self.allocator(0, 0)
        for channel in UInt8(1)...16 { #expect(live.note(on: channel) == nil) }
        #expect(throws: MPERefusal.zoneOff(.lower)) { try live.allocate(note: 60, zone: .lower) }
        #expect(throws: MPERefusal.zoneOff(.upper)) { try live.allocate(note: 60, zone: .upper) }
        #expect(live == (try Self.allocator(0, 0)))
    }
}
