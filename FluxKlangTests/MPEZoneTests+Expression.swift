import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MPEZoneTests {
    static func neutral(cents: Int = 0) -> MPEExpressionValues {
        MPEExpressionValues(pressure: 0, slide: 0, pitchBend: 8192, bendCents: cents)
    }

    /// An expression state with each (note, channel) pair bound in order; the twin of live state in refusal tests.
    static func bound(
        _ lower: Int, _ upper: Int, _ pairs: [(UInt8, UInt8)], range: Int = 48
    ) throws -> MPENoteExpression {
        var made = try expression(lower, upper, range: range)
        for (note, channel) in pairs { try made.bind(note: note, channel: channel) }
        return made
    }

    @Test func bendRangeOneAndNinetySixAreAcceptedAndZeroAndNinetySevenRefused() throws {
        #expect(try Self.expression(3, 0, range: 1).bendRange == 1)
        #expect(try Self.expression(3, 0, range: 96).bendRange == 96)
        #expect(try Self.expression(3, 0, range: MPEZoneConfiguration.specificationDefaultBendRange).bendRange == 48)
        for range in [0, 97, -1, 1_000] {
            #expect(throws: MPERefusal.invalidBendRange(range)) { try Self.expression(3, 0, range: range) }
        }
    }

    @Test func bindingRefusesInvalidChannelThenInvalidNoteThenNonMemberThenBusyChannelThenBoundNote() throws {
        var live = try Self.bound(3, 2, [(60, 2)])
        #expect(throws: MPERefusal.invalidChannel(0)) { try live.bind(note: 200, channel: 0) }
        #expect(throws: MPERefusal.invalidNote(200)) { try live.bind(note: 200, channel: 1) }
        #expect(throws: MPERefusal.notMemberChannel(1)) { try live.bind(note: 60, channel: 1) }
        #expect(throws: MPERefusal.notMemberChannel(8)) { try live.bind(note: 61, channel: 8) }
        #expect(throws: MPERefusal.channelAlreadyBound(2)) { try live.bind(note: 60, channel: 2) }
        #expect(throws: MPERefusal.noteAlreadyBound(60)) { try live.bind(note: 60, channel: 3) }
        #expect(live == (try Self.bound(3, 2, [(60, 2)])))
    }

    @Test func bindingAcceptsNote127AndRefusesNote128() throws {
        var live = try Self.expression(3, 0)
        try live.bind(note: 127, channel: 2)
        try live.bind(note: 0, channel: 3)
        #expect(throws: MPERefusal.invalidNote(128)) { try live.bind(note: 128, channel: 4) }
        #expect(live.boundNote(on: 2) == 127)
        #expect(live.boundNote(on: 3) == 0)
        #expect(live.boundNote(on: 4) == nil)
    }

    @Test func theSameNoteMayBeBoundInBothZonesButNotTwiceInOneZone() throws {
        var live = try Self.expression(3, 2)
        try live.bind(note: 60, channel: 2)
        try live.bind(note: 60, channel: 15)
        #expect(throws: MPERefusal.noteAlreadyBound(60)) { try live.bind(note: 60, channel: 14) }
        #expect(throws: MPERefusal.noteAlreadyBound(60)) { try live.bind(note: 60, channel: 4) }
        #expect(live.boundNote(on: 2) == 60)
        #expect(live.boundNote(on: 15) == 60)
    }

    @Test func channelPressureOnAMemberChannelUpdatesOnlyThatNoteAndTheLastValueWins() throws {
        var live = try Self.bound(3, 0, [(60, 2), (62, 3)])
        let first = try live.apply(.channelPressure(channel: 2, pressure: 10))
        #expect(first.target == .note(channel: 2))
        let second = try live.apply(.channelPressure(channel: 2, pressure: 90))
        let member = MPEExpressionValues(pressure: 90, slide: 0, pitchBend: 8192, bendCents: 0)
        #expect(second.entries == [MPEExpressionEntry(channel: 2, note: 60, member: member, zone: Self.neutral())])
        #expect(live.memberValues(on: 2) == member)
        #expect(live.memberValues(on: 3) == Self.neutral())
    }

    @Test func pitchBendReportsTheRawValueAndTruncatedCentsAtTheBendRange() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        let expected: [(UInt16, Int)] = [(16_383, 4_799), (0, -4_800), (8_192, 0), (12_288, 2_400), (8_191, 0)]
        for (raw, cents) in expected {
            let update = try live.apply(.pitchBend(channel: 2, value: raw))
            let entry = try #require(update.entries.first)
            #expect(entry.member.pitchBend == raw)
            #expect(entry.member.bendCents == cents)
        }
        var narrow = try Self.bound(3, 0, [(60, 2)], range: 1)
        #expect(try Self.send(&narrow, .pitchBend(channel: 2, value: 16_383)).entries.first?.member.bendCents == 99)
        #expect(try Self.send(&narrow, .pitchBend(channel: 2, value: 0)).entries.first?.member.bendCents == -100)
        #expect(try Self.send(&narrow, .pitchBend(channel: 2, value: 8_190)).entries.first?.member.bendCents == 0)
        var wide = try Self.bound(3, 0, [(60, 2)], range: 96)
        #expect(try Self.send(&wide, .pitchBend(channel: 2, value: 0)).entries.first?.member.bendCents == -9_600)
        #expect(try Self.send(&wide, .pitchBend(channel: 2, value: 16_383)).entries.first?.member.bendCents == 9_598)
    }

    @Test func controllerSeventyFourIsSlideAndNeighbouringControllersAreNotExpression() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        let update = try live.apply(.controlChange(channel: 2, controller: 74, value: 100))
        #expect(update.entries.first?.member.slide == 100)
        #expect(update.entries.first?.member.pressure == 0)
        for controller in [UInt8(73), 75, 1, 0] {
            #expect(throws: MPERefusal.notExpressionMessage) {
                try live.apply(.controlChange(channel: 2, controller: controller, value: 5))
            }
        }
        #expect(live.memberValues(on: 2)?.slide == 100)
    }

    @Test func messagesThatAreNotPressureBendOrSlideAreRefusedAsNotExpression() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        let others: [MIDI1Semantic] = [
            .noteOn(channel: 2, note: 60, velocity: 90), .noteOff(channel: 2, note: 60, velocity: 0),
            .polyphonicPressure(channel: 2, note: 60, pressure: 5), .programChange(channel: 2, program: 1),
            .systemCommon(status: 0xF2, data1: 1, data2: 2), .realTime(status: 0xF8), .sysEx(payload: [1])
        ]
        for message in others {
            #expect(throws: MPERefusal.notExpressionMessage) { try live.apply(message) }
        }
        #expect(live == (try Self.bound(3, 0, [(60, 2)])))
    }

    @Test func anExpressionOnAnUnboundMemberOrAnUnassignedChannelIsRefusedAsUnbound() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        #expect(throws: MPERefusal.unboundChannel(3)) { try live.apply(.channelPressure(channel: 3, pressure: 5)) }
        #expect(throws: MPERefusal.unboundChannel(8)) { try live.apply(.pitchBend(channel: 8, value: 100)) }
        #expect(throws: MPERefusal.unboundChannel(16)) { try live.apply(.pitchBend(channel: 16, value: 100)) }
        #expect(live == (try Self.bound(3, 0, [(60, 2)])))
    }

    @Test func aManagerMessageUpdatesTheZoneForEveryBoundNoteInAscendingChannelOrder() throws {
        var live = try Self.bound(4, 2, [(64, 4), (60, 2), (62, 3), (71, 15), (70, 14)])
        _ = try live.apply(.channelPressure(channel: 3, pressure: 33))
        let update = try live.apply(.pitchBend(channel: 1, value: 16_383))
        let zone = MPEExpressionValues(pressure: 0, slide: 0, pitchBend: 16_383, bendCents: 4_799)
        #expect(update.target == .zone(.lower))
        #expect(update.entries.map(\.channel) == [2, 3, 4])
        #expect(update.entries.map(\.note) == [60, 62, 64])
        #expect(update.entries.allSatisfy { $0.zone == zone })
        let channel3 = try #require(update.entries.first { $0.channel == 3 })
        #expect(channel3.member.pressure == 33)
        #expect(live.zoneValues(.lower) == zone)
        #expect(live.zoneValues(.upper) == Self.neutral())
        let upper = try live.apply(.channelPressure(channel: 16, pressure: 7))
        #expect(upper.target == .zone(.upper))
        #expect(upper.entries.map(\.channel) == [14, 15])
        #expect(upper.entries.map(\.note) == [70, 71])
        #expect(live.zoneValues(.lower) == zone)
    }

    @Test func aManagerMessageWithNoBoundNoteStillStoresTheZoneValuesForLaterNotes() throws {
        var live = try Self.expression(3, 0)
        let update = try live.apply(.controlChange(channel: 1, controller: 74, value: 44))
        #expect(update.target == .zone(.lower))
        #expect(update.entries.isEmpty)
        try live.bind(note: 60, channel: 2)
        let slide = MPEExpressionValues(pressure: 0, slide: 44, pitchBend: 8192, bendCents: 0)
        #expect(try Self.send(&live, .channelPressure(channel: 2, pressure: 1)).entries.first?.zone == slide)
    }

    @Test func messageRefusalOrderIsNotExpressionThenChannelThenValueThenBinding() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        #expect(throws: MPERefusal.notExpressionMessage) { try live.apply(.noteOn(channel: 0, note: 60, velocity: 5)) }
        #expect(throws: MPERefusal.invalidChannel(0)) { try live.apply(.channelPressure(channel: 0, pressure: 200)) }
        #expect(throws: MPERefusal.invalidChannel(17)) { try live.apply(.pitchBend(channel: 17, value: 100)) }
        #expect(throws: MPERefusal.valueOutOfRange(200)) { try live.apply(.channelPressure(channel: 8, pressure: 200)) }
        #expect(throws: MPERefusal.unboundChannel(8)) { try live.apply(.channelPressure(channel: 8, pressure: 5)) }
        #expect(live == (try Self.bound(3, 0, [(60, 2)])))
    }

    @Test func valuesAreAcceptedAtTheLimitAndRefusedOneAbove() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        _ = try live.apply(.channelPressure(channel: 2, pressure: 127))
        _ = try live.apply(.controlChange(channel: 2, controller: 74, value: 127))
        _ = try live.apply(.pitchBend(channel: 2, value: 16_383))
        let held = live
        #expect(throws: MPERefusal.valueOutOfRange(128)) { try live.apply(.channelPressure(channel: 2, pressure: 128)) }
        #expect(throws: MPERefusal.valueOutOfRange(129)) {
            try live.apply(.controlChange(channel: 2, controller: 74, value: 129))
        }
        #expect(throws: MPERefusal.valueOutOfRange(16_384)) { try live.apply(.pitchBend(channel: 2, value: 16_384)) }
        #expect(live == held)
        _ = try live.apply(.pitchBend(channel: 2, value: 0))
        #expect(live.memberValues(on: 2)?.pitchBend == 0)
    }

    @Test func unbindingReturnsTheNoteFreesTheChannelAndARebindStartsNeutral() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        _ = try live.apply(.channelPressure(channel: 2, pressure: 99))
        #expect(Self.unbound(&live, 2) == 60)
        #expect(Self.unbound(&live, 2) == nil)
        #expect(Self.unbound(&live, 0) == nil)
        #expect(live.memberValues(on: 2) == nil)
        #expect(throws: MPERefusal.unboundChannel(2)) { try live.apply(.channelPressure(channel: 2, pressure: 5)) }
        try live.bind(note: 61, channel: 2)
        #expect(live.memberValues(on: 2) == Self.neutral())
    }

    @Test func lookupsOutsideOneToSixteenAndOnFreeChannelsAreNil() throws {
        let live = try Self.bound(3, 2, [(60, 2)])
        for channel in [UInt8(0), 17, 255, 3, 1, 16] {
            #expect(live.boundNote(on: channel) == nil)
            #expect(live.memberValues(on: channel) == nil)
        }
        #expect(live.boundNote(on: 2) == 60)
    }

    @Test func memberMessagesInOneZoneNeverTouchTheOtherZone() throws {
        var live = try Self.bound(3, 2, [(60, 2), (60, 15)])
        _ = try live.apply(.pitchBend(channel: 15, value: 0))
        #expect(live.memberValues(on: 15)?.pitchBend == 0)
        #expect(live.memberValues(on: 2) == Self.neutral())
        #expect(live.zoneValues(.lower) == Self.neutral())
        #expect(live.zoneValues(.upper) == Self.neutral())
    }
}
