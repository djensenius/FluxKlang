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

    /// The three builders' results for one channel, in the order pressure 77, slide 78, pitch bend 12_345.
    static func mpxOutcomes(
        _ channel: UInt8, _ configuration: MPEZoneConfiguration
    ) -> [Result<MIDI1Semantic, MPERefusal>] {
        [
            Result { () throws(MPERefusal) in
                try MPEExpressionMessages.pressure(channel: channel, value: 77, in: configuration)
            },
            Result { () throws(MPERefusal) in
                try MPEExpressionMessages.slide(channel: channel, value: 78, in: configuration)
            },
            Result { () throws(MPERefusal) in
                try MPEExpressionMessages.pitchBend(channel: channel, value: 12_345, in: configuration)
            }
        ]
    }

    @Test func expressionBuildersEmitTheExactMessageOnMemberAndManagerChannels() throws {
        let lowerOnly = try Self.config(5, 0)
        #expect(try MPEExpressionMessages.pressure(channel: 3, value: 100, in: lowerOnly)
            == .channelPressure(channel: 3, pressure: 100))
        #expect(try MPEExpressionMessages.slide(channel: 3, value: 64, in: lowerOnly)
            == .controlChange(channel: 3, controller: 74, value: 64))
        #expect(try MPEExpressionMessages.pitchBend(channel: 3, value: 16_383, in: lowerOnly)
            == .pitchBend(channel: 3, value: 16_383))
        #expect(try MPEExpressionMessages.pressure(channel: 1, value: 0, in: lowerOnly)
            == .channelPressure(channel: 1, pressure: 0))
        let upperOnly = try Self.config(0, 3)
        #expect(try MPEExpressionMessages.slide(channel: 16, value: 127, in: upperOnly)
            == .controlChange(channel: 16, controller: 74, value: 127))
        #expect(try MPEExpressionMessages.pitchBend(channel: 13, value: 8_192, in: upperOnly)
            == .pitchBend(channel: 13, value: 8_192))
    }

    @Test func expressionBuildersAcceptTheLimitsAndRefuseOneAboveWithoutClamping() throws {
        let lowerOnly = try Self.config(5, 0)
        for value in [UInt8(0), 127] {
            #expect(try MPEExpressionMessages.pressure(channel: 3, value: value, in: lowerOnly)
                == .channelPressure(channel: 3, pressure: value))
            #expect(try MPEExpressionMessages.slide(channel: 3, value: value, in: lowerOnly)
                == .controlChange(channel: 3, controller: 74, value: value))
        }
        for value in [UInt8(128), 255] {
            #expect(throws: MPERefusal.valueOutOfRange(UInt16(value))) {
                try MPEExpressionMessages.pressure(channel: 3, value: value, in: lowerOnly)
            }
            #expect(throws: MPERefusal.valueOutOfRange(UInt16(value))) {
                try MPEExpressionMessages.slide(channel: 3, value: value, in: lowerOnly)
            }
        }
        for value in [UInt16(0), 8_192, 16_383] {
            #expect(try MPEExpressionMessages.pitchBend(channel: 3, value: value, in: lowerOnly)
                == .pitchBend(channel: 3, value: value))
        }
        for value in [UInt16(16_384), 65_535] {
            #expect(throws: MPERefusal.valueOutOfRange(value)) {
                try MPEExpressionMessages.pitchBend(channel: 3, value: value, in: lowerOnly)
            }
        }
        let managers: [(MPEZoneConfiguration, UInt8)] = [(lowerOnly, 1), (try Self.config(0, 3), 16)]
        for (configuration, channel) in managers {
            #expect(try MPEExpressionMessages.pressure(channel: channel, value: 127, in: configuration)
                == .channelPressure(channel: channel, pressure: 127))
            #expect(try MPEExpressionMessages.slide(channel: channel, value: 127, in: configuration)
                == .controlChange(channel: channel, controller: 74, value: 127))
            #expect(try MPEExpressionMessages.pitchBend(channel: channel, value: 16_383, in: configuration)
                == .pitchBend(channel: channel, value: 16_383))
            #expect(throws: MPERefusal.valueOutOfRange(128)) {
                try MPEExpressionMessages.pressure(channel: channel, value: 128, in: configuration)
            }
            #expect(throws: MPERefusal.valueOutOfRange(128)) {
                try MPEExpressionMessages.slide(channel: channel, value: 128, in: configuration)
            }
            #expect(throws: MPERefusal.valueOutOfRange(16_384)) {
                try MPEExpressionMessages.pitchBend(channel: channel, value: 16_384, in: configuration)
            }
        }
    }

    @Test func expressionBuildersRefuseChannelsZeroSeventeenAndTwoFiftyFiveAsInvalid() throws {
        let both = try Self.config(3, 5)
        for channel in [UInt8(0), 17, 255] {
            #expect(throws: MPERefusal.invalidChannel(channel)) {
                try MPEExpressionMessages.pressure(channel: channel, value: 1, in: both)
            }
            #expect(throws: MPERefusal.invalidChannel(channel)) {
                try MPEExpressionMessages.slide(channel: channel, value: 1, in: both)
            }
            #expect(throws: MPERefusal.invalidChannel(channel)) {
                try MPEExpressionMessages.pitchBend(channel: channel, value: 1, in: both)
            }
        }
    }

    @Test func expressionBuildersRefuseUnassignedChannelsAndAcceptTheEdgeMembers() throws {
        let unassigned: [((Int, Int), [UInt8])] = [((3, 5), [5, 10]), ((0, 0), [1, 16]), ((0, 5), [1]), ((5, 0), [16])]
        for (layout, channels) in unassigned {
            let configuration = try Self.config(layout.0, layout.1)
            for channel in channels {
                for outcome in Self.mpxOutcomes(channel, configuration) {
                    #expect(throws: MPERefusal.unboundChannel(channel)) { try outcome.get() }
                }
            }
        }
        let accepted: [((Int, Int), [UInt8])] = [((15, 0), [16]), ((0, 15), [1, 16])]
        for (layout, channels) in accepted {
            for channel in channels {
                let outcomes = Self.mpxOutcomes(channel, try Self.config(layout.0, layout.1))
                try #require(outcomes.count == 3)
                #expect(try outcomes[0].get() == .channelPressure(channel: channel, pressure: 77))
                #expect(try outcomes[1].get() == .controlChange(channel: channel, controller: 74, value: 78))
                #expect(try outcomes[2].get() == .pitchBend(channel: channel, value: 12_345))
            }
        }
    }

    @Test func expressionBuilderRefusalOrderIsChannelThenValueThenRole() throws {
        let off = try Self.config(0, 0)
        #expect(throws: MPERefusal.invalidChannel(0)) {
            try MPEExpressionMessages.pressure(channel: 0, value: 255, in: off)
        }
        #expect(throws: MPERefusal.valueOutOfRange(255)) {
            try MPEExpressionMessages.pressure(channel: 5, value: 255, in: off)
        }
        #expect(throws: MPERefusal.unboundChannel(5)) {
            try MPEExpressionMessages.pressure(channel: 5, value: 5, in: off)
        }
        #expect(throws: MPERefusal.invalidChannel(0)) {
            try MPEExpressionMessages.slide(channel: 0, value: 255, in: off)
        }
        #expect(throws: MPERefusal.valueOutOfRange(255)) {
            try MPEExpressionMessages.slide(channel: 5, value: 255, in: off)
        }
        #expect(throws: MPERefusal.unboundChannel(5)) {
            try MPEExpressionMessages.slide(channel: 5, value: 5, in: off)
        }
        #expect(throws: MPERefusal.invalidChannel(17)) {
            try MPEExpressionMessages.pitchBend(channel: 17, value: 65_535, in: off)
        }
        #expect(throws: MPERefusal.valueOutOfRange(65_535)) {
            try MPEExpressionMessages.pitchBend(channel: 5, value: 65_535, in: off)
        }
        #expect(throws: MPERefusal.unboundChannel(5)) {
            try MPEExpressionMessages.pitchBend(channel: 5, value: 5, in: off)
        }
    }

    @Test func expressionBuilderMessagesRoundTripThroughTheReceiverAndAnUnboundMemberIsRefusedThere() throws {
        var live = try Self.bound(3, 0, [(60, 2)])
        let pressure = try MPEExpressionMessages.pressure(channel: 2, value: 90, in: live.configuration)
        let first = try live.apply(pressure)
        let member = MPEExpressionValues(pressure: 90, slide: 0, pitchBend: 8192, bendCents: 0)
        #expect(first.target == .note(channel: 2))
        #expect(first.entries == [MPEExpressionEntry(channel: 2, note: 60, member: member, zone: Self.neutral())])
        let slide = try MPEExpressionMessages.slide(channel: 2, value: 64, in: live.configuration)
        #expect(try live.apply(slide).entries.first?.member.slide == 64)
        let bend = try MPEExpressionMessages.pitchBend(channel: 2, value: 16_383, in: live.configuration)
        let bent = try #require(try live.apply(bend).entries.first)
        #expect(bent.member.pitchBend == 16_383)
        #expect(bent.member.bendCents == 4_799)
        let manager = try MPEExpressionMessages.pressure(channel: 1, value: 33, in: live.configuration)
        let zoneUpdate = try live.apply(manager)
        #expect(zoneUpdate.target == .zone(.lower))
        #expect(zoneUpdate.entries.count == 1)
        let entry = try #require(zoneUpdate.entries.first)
        #expect(entry.channel == 2)
        #expect(entry.note == 60)
        #expect(entry.zone.pressure == 33)
        let unbound = try MPEExpressionMessages.pressure(channel: 3, value: 5, in: live.configuration)
        #expect(unbound == .channelPressure(channel: 3, pressure: 5))
        #expect(throws: MPERefusal.unboundChannel(3)) { try live.apply(unbound) }
    }

    @Test func expressionBuildersMatchAnIndependentRoleOracleForEveryLayoutAndChannel() throws {
        var cases = 0
        for (lower, upper) in Self.allValidPairs() {
            let configuration = try Self.config(lower, upper)
            for channel in UInt8(1)...16 {
                let lowerManager = lower > 0 && channel == 1
                let upperManager = upper > 0 && channel == 16
                let lowerMember = lower > 0 && (2...(1 + lower)).contains(Int(channel))
                let upperMember = upper > 0 && ((16 - upper)...15).contains(Int(channel))
                let assigned = lowerManager || upperManager || lowerMember || upperMember
                let outcomes = Self.mpxOutcomes(channel, configuration)
                try #require(outcomes.count == 3)
                if assigned {
                    #expect(try outcomes[0].get() == .channelPressure(channel: channel, pressure: 77))
                    #expect(try outcomes[1].get() == .controlChange(channel: channel, controller: 74, value: 78))
                    #expect(try outcomes[2].get() == .pitchBend(channel: channel, value: 12_345))
                } else {
                    for outcome in outcomes {
                        #expect(throws: MPERefusal.unboundChannel(channel)) { try outcome.get() }
                    }
                }
                cases += outcomes.count
            }
        }
        #expect(cases == 5_856)
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
