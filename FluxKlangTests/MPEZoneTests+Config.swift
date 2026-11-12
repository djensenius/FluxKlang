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

/// The MPE Configuration Message encoder and the zone tracker (slice MPC1).
extension MPEZoneTests {
    static let rpn6 = MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 6)
    static let zoneManagers: [(MPEZone, UInt8)] = [(.lower, 1), (.upper, 16)]

    static func cc(_ channel: UInt8, _ controller: UInt8, _ value: UInt8) -> MIDI1Semantic {
        .controlChange(channel: channel, controller: controller, value: value)
    }

    /// The RPN 6 data entry sequence a receiver sees, written out by hand.
    static func selectRPN6(_ channel: UInt8, then data: [MIDI1Semantic] = []) -> [MIDI1Semantic] {
        [cc(channel, 101, 0), cc(channel, 100, 6)] + data
    }

    static func forged(_ channel: UInt8?, _ value: UInt16) -> MIDI1StateUpdate {
        MIDI1StateUpdate(channel: channel, effect: .parameter(rpn6, value: value))
    }

    static func feed(_ state: inout MIDI1PerformanceState, _ messages: [MIDI1Semantic]) throws -> [MIDI1StateUpdate] {
        var updates: [MIDI1StateUpdate] = []
        for message in messages { updates.append(try state.apply(message)) }
        return updates
    }

    static func track(_ tracker: inout MPEZoneTracker, _ update: MIDI1StateUpdate) throws -> MPEZoneChange? {
        try tracker.apply(update)
    }

    static func refusal(_ tracker: inout MPEZoneTracker, _ update: MIDI1StateUpdate) -> MPERefusal? {
        do { _ = try tracker.apply(update) } catch { return error }
        return nil
    }

    /// Feeds `messages` through a fresh state into `tracker` and returns each tracker result.
    static func run(_ tracker: inout MPEZoneTracker, _ messages: [MIDI1Semantic]) throws -> [MPEZoneChange?] {
        var state = MIDI1PerformanceState()
        var results: [MPEZoneChange?] = []
        for update in try feed(&state, messages) { results.append(try tracker.apply(update)) }
        return results
    }

    @Test func theEncoderEmitsTheThreeGoldenControlChangesOnTheManagerChannel() throws {
        #expect(try MPEConfigurationMessage.messages(zone: .lower, members: 5)
            == [Self.cc(1, 101, 0), Self.cc(1, 100, 6), Self.cc(1, 6, 5)])
        #expect(try MPEConfigurationMessage.messages(zone: .upper, members: 3)
            == [Self.cc(16, 101, 0), Self.cc(16, 100, 6), Self.cc(16, 6, 3)])
        #expect(try MPEConfigurationMessage.messages(zone: .lower, members: 0)
            == [Self.cc(1, 101, 0), Self.cc(1, 100, 6), Self.cc(1, 6, 0)])
        #expect(try MPEConfigurationMessage.messages(zone: .upper, members: 15)
            == [Self.cc(16, 101, 0), Self.cc(16, 100, 6), Self.cc(16, 6, 15)])
    }

    @Test func theEncoderEmitsControllersOneHundredOneOneHundredAndSixForEveryZoneAndCount() throws {
        for (zone, manager) in Self.zoneManagers {
            for count in 0...15 {
                let messages = try MPEConfigurationMessage.messages(zone: zone, members: count)
                try #require(messages.count == 3)
                var channels: [UInt8] = []
                var controllers: [UInt8] = []
                var values: [UInt8] = []
                for case let .controlChange(channel, controller, value) in messages {
                    channels.append(channel)
                    controllers.append(controller)
                    values.append(value)
                }
                #expect(channels == [manager, manager, manager])
                #expect(controllers == [101, 100, 6])
                #expect(values == [0, 6, UInt8(count)])
            }
        }
    }

    @Test func theEncoderRefusesMemberCountsOutsideZeroToFifteenForBothZones() {
        for zone in MPEZone.allCases {
            for count in [-1, 16, 127, 128, 255, Int.min, Int.max] {
                #expect(throws: MPERefusal.invalidMemberCount(count)) {
                    try MPEConfigurationMessage.messages(zone: zone, members: count)
                }
            }
        }
    }

    @Test func theEncodersMessagesBecomeAnRPNSixDataEntryInTheMIDIOneState() throws {
        for (zone, manager) in Self.zoneManagers {
            for count in 0...15 {
                var state = MIDI1PerformanceState()
                let updates = try Self.feed(&state, MPEConfigurationMessage.messages(zone: zone, members: count))
                try #require(updates.count == 3)
                #expect(updates.map(\.channel) == [manager, manager, manager])
                #expect(updates[1].effect == .parameterSelected(Self.rpn6))
                #expect(updates[2].effect == .parameter(Self.rpn6, value: UInt16(count) << 7))
            }
        }
    }

    @Test func theTrackerFollowsTheEncodersMessagesExactlyLikeRPNSixFromEveryStartingLayout() throws {
        for (lower, upper) in Self.allValidPairs() {
            let start = try Self.config(lower, upper)
            for (zone, literalChannel) in [(MPEZone.lower, UInt8(1)), (.upper, 16)] {
                for count in 0...15 {
                    var tracker = MPEZoneTracker(configuration: start)
                    let results = try Self.run(&tracker, MPEConfigurationMessage.messages(zone: zone, members: count))
                    try #require(results.count == 3)
                    let oracle = try MPEZoneConfiguration.fromRPN6(
                        channel: literalChannel, dataEntryMSB: UInt8(count), current: start
                    )
                    #expect(results[0] == nil)
                    #expect(results[1] == nil)
                    #expect(results[2] == oracle)
                    #expect(tracker.configuration == oracle.configuration)
                }
            }
        }
    }

    @Test func aTwoMessageStreamShrinksTheOtherZoneAndTheTrackerReportsIt() throws {
        var tracker = MPEZoneTracker(configuration: try Self.config(0, 0))
        let first = try Self.run(&tracker, MPEConfigurationMessage.messages(zone: .upper, members: 5))
        #expect(first.last == MPEZoneChange(configuration: try Self.config(0, 5), adjustment: nil))
        let second = try Self.run(&tracker, MPEConfigurationMessage.messages(zone: .lower, members: 12))
        let adjustment = MPEZoneAdjustment(zone: .upper, previousMembers: 5, resultingMembers: 2)
        #expect(second.last == MPEZoneChange(configuration: try Self.config(12, 2), adjustment: adjustment))
        #expect(tracker.configuration == (try Self.config(12, 2)))
    }

    @Test func updatesThatAreNotAnRPNSixDataEntryReturnNilAndLeaveTheTrackerUnchanged() throws {
        let start = try Self.config(3, 5)
        var tracker = MPEZoneTracker(configuration: start)
        let before = tracker
        var state = MIDI1PerformanceState()
        var updates = try Self.feed(&state, [
            .noteOn(channel: 1, note: 60, velocity: 90), .pitchBend(channel: 1, value: 9000),
            Self.cc(1, 7, 100), Self.cc(1, 74, 20)
        ])
        updates += try Self.feed(&state, Self.selectRPN6(1))
        updates += try Self.feed(&state, [Self.cc(1, 101, 127), Self.cc(1, 100, 127)])
        var nrpn = MIDI1PerformanceState()
        updates += try Self.feed(&nrpn, [Self.cc(1, 99, 0), Self.cc(1, 98, 6), Self.cc(1, 6, 5)])
        var other = MIDI1PerformanceState()
        updates += try Self.feed(&other, Self.selectRPN6(1, then: [Self.cc(1, 100, 5), Self.cc(1, 6, 5)]))
        updates += try Self.feed(&other, [Self.cc(1, 100, 2), Self.cc(1, 6, 5)])
        for msb: UInt8 in [1, 127] {
            var wrongMSB = MIDI1PerformanceState()
            let entry = [Self.cc(1, 101, msb), Self.cc(1, 100, 6), Self.cc(1, 6, 9)]
            let fed = try Self.feed(&wrongMSB, entry)
            try #require(fed.count == 3)
            let number = MIDI1ParameterNumber(kind: .registered, msb: msb, lsb: 6)
            #expect(fed[2].effect == .parameter(number, value: 9 << 7))
            updates += fed
        }
        updates += try Self.feed(&other, [.realTime(status: 0xF8)])
        #expect(updates.last == MIDI1StateUpdate(channel: nil, effect: .unchanged))
        #expect(updates.contains { $0.effect == .parameterSelected(Self.rpn6) })
        #expect(updates.contains { $0.effect == .parameter(MIDI1ParameterNumber(kind: .nonRegistered, msb: 0, lsb: 6),
                                                          value: 5 << 7) })
        for update in updates {
            #expect(try Self.track(&tracker, update) == nil)
            #expect(tracker == before)
        }
    }

    @Test func onlyTheMSBCountsSoTheDataEntryLSBIsIgnored() throws {
        var tracker = MPEZoneTracker(configuration: try Self.config(0, 0))
        let both = try Self.run(&tracker, Self.selectRPN6(1, then: [Self.cc(1, 6, 5), Self.cc(1, 38, 100)]))
        try #require(both.count == 4)
        #expect(both[2]?.configuration == (try Self.config(5, 0)))
        #expect(both[3] == MPEZoneChange(configuration: try Self.config(5, 0), adjustment: nil))
        var forgedTracker = MPEZoneTracker(configuration: try Self.config(0, 0))
        var changes: [MPEZoneChange?] = []
        for lsb: UInt16 in [0, 1, 64, 127] {
            changes.append(try Self.track(&forgedTracker, Self.forged(1, 5 << 7 | lsb)))
        }
        try #require(changes.count == 4)
        #expect(changes.allSatisfy { $0 == changes[0] && $0?.configuration == (try? Self.config(5, 0)) })
        let retain = try #require(MIDI1StatePolicy(lsbReset: .retainLSB))
        var retained = MIDI1PerformanceState(policy: retain)
        var retainTracker = MPEZoneTracker(configuration: try Self.config(0, 0))
        let updates = try Self.feed(&retained, Self.selectRPN6(1, then: [Self.cc(1, 38, 100), Self.cc(1, 6, 5)]))
        try #require(updates.count == 4)
        #expect(updates[3].effect == .parameter(Self.rpn6, value: 5 << 7 | 100))
        #expect(try Self.track(&retainTracker, updates[3])?.configuration == (try Self.config(5, 0)))
    }

    @Test func anLSBSentBeforeItsMSBReadsAsZoneOffUntilTheMSBArrives() throws {
        var tracker = MPEZoneTracker(configuration: try Self.config(4, 0))
        let results = try Self.run(&tracker, Self.selectRPN6(1, then: [Self.cc(1, 38, 100), Self.cc(1, 6, 5)]))
        try #require(results.count == 4)
        #expect(results[2] == MPEZoneChange(configuration: try Self.config(0, 0), adjustment: nil))
        #expect(results[3] == MPEZoneChange(configuration: try Self.config(5, 0), adjustment: nil))
        #expect(tracker.configuration == (try Self.config(5, 0)))
    }

    @Test func refusalsPassThroughTheTrackerAndLeaveItUnchanged() throws {
        let start = try Self.config(2, 2)
        for channel in UInt8(2)...15 {
            var tracker = MPEZoneTracker(configuration: start)
            var state = MIDI1PerformanceState()
            let updates = try Self.feed(&state, Self.selectRPN6(channel, then: [Self.cc(channel, 6, 3)]))
            try #require(updates.count == 3)
            #expect(Self.refusal(&tracker, updates[2]) == .notManagerChannel(channel))
            #expect(tracker == MPEZoneTracker(configuration: start))
        }
        for count: UInt8 in [16, 127] {
            var tracker = MPEZoneTracker(configuration: start)
            var state = MIDI1PerformanceState()
            let updates = try Self.feed(&state, Self.selectRPN6(1, then: [Self.cc(1, 6, count)]))
            try #require(updates.count == 3)
            #expect(Self.refusal(&tracker, updates[2]) == .invalidMemberCount(Int(count)))
            #expect(tracker == MPEZoneTracker(configuration: start))
        }
    }

    @Test func forgedUpdatesAreRefusedInTheDocumentedOrder() throws {
        let start = try Self.config(2, 2)
        var tracker = MPEZoneTracker(configuration: start)
        let cases: [(MIDI1StateUpdate, MPERefusal)] = [
            (Self.forged(nil, 5 << 7), .invalidChannel(0)), (Self.forged(0, 5 << 7), .invalidChannel(0)),
            (Self.forged(17, 5 << 7), .invalidChannel(17)), (Self.forged(1, 0x4000), .valueOutOfRange(0x4000)),
            (Self.forged(1, 0xFFFF), .valueOutOfRange(0xFFFF)), (Self.forged(1, 0x3FFF), .invalidMemberCount(127)),
            (Self.forged(nil, 0xFFFF), .invalidChannel(0)), (Self.forged(5, 0xFFFF), .valueOutOfRange(0xFFFF)),
            (Self.forged(5, 5 << 7), .notManagerChannel(5))
        ]
        for (update, expected) in cases {
            #expect(Self.refusal(&tracker, update) == expected)
            #expect(tracker == MPEZoneTracker(configuration: start))
        }
    }

    @Test func everyValueFromZeroToSixtyFiveThousandFiveHundredThirtyFiveIsDecidedByTheRulesWithoutTrapping() throws {
        let start = MPEZoneTracker(configuration: try Self.config(0, 0))
        for value in UInt16.min...UInt16.max {
            var tracker = start
            let update = Self.forged(1, value)
            if value > 0x3FFF {
                #expect(Self.refusal(&tracker, update) == .valueOutOfRange(value))
            } else if value >> 7 > 15 {
                #expect(Self.refusal(&tracker, update) == .invalidMemberCount(Int(value >> 7)))
            } else {
                #expect(try Self.track(&tracker, update)?.configuration.lowerMembers == Int(value >> 7))
            }
        }
    }

    @Test func dataIncrementAndDecrementMoveTheFourteenBitValueSoTheTrackerReadsTheSteppedMSB() throws {
        var tracker = MPEZoneTracker(configuration: try Self.config(0, 0))
        var state = MIDI1PerformanceState()
        let steps = [Self.cc(1, 6, 5), Self.cc(1, 97, 0), Self.cc(1, 96, 0)]
        let updates = try Self.feed(&state, Self.selectRPN6(1, then: steps))
        try #require(updates.count == 5)
        #expect(updates[3].effect == .parameter(Self.rpn6, value: (5 << 7) - 1))
        #expect(updates[4].effect == .parameter(Self.rpn6, value: 5 << 7))
        #expect(try Self.track(&tracker, updates[2])?.configuration == (try Self.config(5, 0)))
        #expect(try Self.track(&tracker, updates[3])?.configuration == (try Self.config(4, 0)))
        #expect(try Self.track(&tracker, updates[4])?.configuration == (try Self.config(5, 0)))
    }

    @Test func theTrackerStartsFromTheLayoutItIsGivenAndKeepsItAcrossUnrelatedUpdates() throws {
        var tracker = MPEZoneTracker(configuration: try Self.config(3, 5))
        #expect(tracker.configuration == (try Self.config(3, 5)))
        #expect(try Self.track(&tracker, MIDI1StateUpdate(channel: 1, effect: .controller(7, value: 9))) == nil)
        #expect(tracker.configuration == (try Self.config(3, 5)))
        var first = MPEZoneTracker(configuration: try Self.config(3, 5))
        var second = MPEZoneTracker(configuration: try Self.config(3, 5))
        var different = MPEZoneTracker(configuration: try Self.config(5, 3))
        let messages = try MPEConfigurationMessage.messages(zone: .lower, members: 4)
        _ = try Self.run(&first, messages)
        _ = try Self.run(&second, messages)
        _ = try Self.run(&different, messages)
        #expect(first == second)
        #expect(first != different)
        let swapped = MPEZoneTracker(configuration: try Self.config(5, 3))
        #expect(MPEZoneTracker(configuration: try Self.config(3, 5)) != swapped)
    }
}
