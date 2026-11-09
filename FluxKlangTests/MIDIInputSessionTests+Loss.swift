import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIInputSessionTests {
    /// Keys registered with a sensing policy, armed at tick 0 and holding note 60 from tick 10: the deadline is 110.
    private static func armedWithKeyHeld(
        _ action: ActiveSensingLossAction = .requestInputLost, heldNotes: Int = 128,
        reset: MIDISystemResetPolicy = .ignore
    ) throws -> MIDIInputSession {
        var built = try session(
            [keys], sensing: policy(action), profile: profile(reset: reset, heldNotes: heldNotes)
        )
        _ = try play(&built, activeSensing, at: 0)
        _ = try play(&built, noteOn(60), at: 10)
        return built
    }

    /// The Sustain pedal going up (controller 64, value 0) on channel 1 of a route, as a forced release sends it.
    private static func sentSustainUp(_ route: MIDIRouteID) -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: .controlChange(channel: 1, controller: 64, value: 0))
    }

    @Test
    func midiInputSessionPollLossReleasesOnceWhenTheLossActionRequestsIt() throws {
        var session = try Self.armedWithKeyHeld()
        let registryBefore = session.registry.snapshot
        let lost = try session.poll(at: Self.stamp(200))
        let expected = Self.result([Self.sentOff(Self.piano, 60)], notices: [.sensingLostReleased(Self.keys)])
        #expect(lost == expected)
        let lostPhase = ActiveSensingPhase.lost(since: 110)
        let phase = Self.phase(session)
        #expect(phase == lostPhase)
        let registryAfter = session.registry.snapshot
        #expect(registryAfter == registryBefore)
        let again = try session.poll(at: Self.stamp(300))
        #expect(again == Self.empty)
        // A System Exclusive dump still open emits no event, yet each of its bytes moves the deadline on.
        var dumping = try Self.armedWithKeyHeld()
        let opened = try Self.play(&dumping, [0xF0, 0x01, 0x02], at: 100)
        #expect(opened == Self.empty)
        let alive = try dumping.poll(at: Self.stamp(150))
        #expect(alive == Self.empty)
        let dumpLost = try dumping.poll(at: Self.stamp(200))
        #expect(dumpLost == expected)
        let dumpPhase = ActiveSensingPhase.lost(since: 200)
        let afterDump = Self.phase(dumping)
        #expect(afterDump == dumpPhase)
    }

    @Test
    func midiInputSessionLateFeedReleasesBeforeThePacketsOwnNotes() throws {
        var session = try Self.armedWithKeyHeld()
        let late = try Self.play(&session, Self.noteOn(62), at: 300)
        let expected = Self.result(
            [Self.sentOff(Self.piano, 60), Self.sentOn(Self.piano, 62, 100)], notices: [.sensingLostReleased(Self.keys)]
        )
        #expect(late == expected)
        let stillHeld = session.ledger.notes.map(\.note)
        #expect(stillHeld == [62])
        let lostPhase = ActiveSensingPhase.lost(since: 110)
        let phase = Self.phase(session)
        #expect(phase == lostPhase)
        var fresh = try Self.armedWithKeyHeld()
        let sensing = try Self.play(&fresh, Self.activeSensing, at: 300)
        let expectedSensing = Self.result([Self.sentOff(Self.piano, 60)], notices: [.sensingLostReleased(Self.keys)])
        #expect(sensing == expectedSensing)
        let rearmed = ActiveSensingPhase.armed(deadline: 400)
        let freshPhase = Self.phase(fresh)
        #expect(freshPhase == rearmed)
    }

    @Test
    func midiInputSessionReportOnlyLossReleasesNothing() throws {
        var session = try Self.armedWithKeyHeld(.reportOnly)
        let lost = try session.poll(at: Self.stamp(200))
        let expected = Self.result(notices: [.sensingLostReported(Self.keys)])
        #expect(lost == expected)
        let lostPhase = ActiveSensingPhase.lost(since: 110)
        let phase = Self.phase(session)
        #expect(phase == lostPhase)
        let stillHeld = session.ledger.notes.map(\.note)
        #expect(stillHeld == [60])
        var late = try Self.armedWithKeyHeld(.reportOnly)
        let fed = try Self.play(&late, Self.noteOn(62), at: 300)
        let expectedFed = Self.result([Self.sentOn(Self.piano, 62, 100)], notices: [.sensingLostReported(Self.keys)])
        #expect(fed == expectedFed)
        let lateHeld = late.ledger.notes.map(\.note)
        #expect(lateHeld == [60, 62])
    }

    @Test
    func midiInputSessionUnarmedAndUnconfiguredInputsReportNoLoss() throws {
        var session = try MIDIInputSession.make()
        try session.register(Self.keys, key: Self.key(Self.keys), sensing: Self.policy())
        try session.register(Self.pads, key: Self.key(Self.pads))
        _ = try Self.play(&session, Self.noteOn(60), at: 10)
        let quiet = try session.poll(at: Self.stamp(UInt64.max))
        #expect(quiet == Self.empty)
        let observer = try #require(session.observer(of: Self.keys))
        let unarmed = ActiveSensingPhase.unarmed
        #expect(observer.phase == unarmed)
        #expect(observer.lastTick == UInt64.max)
        let stillHeld = session.ledger.notes.map(\.note)
        #expect(stillHeld == [60])
        let unconfigured = session.observer(of: Self.pads)
        #expect(unconfigured == nil)
        let first = try Self.play(&session, Self.noteOn(62), from: Self.pads, at: UInt64.max)
        let second = try Self.play(&session, Self.noteOff(62), from: Self.pads, at: 0)
        let expectedFirst = Self.result([Self.sentOn(Self.strings, 62, 100)])
        let expectedSecond = Self.result([Self.sentOff(Self.strings, 62)])
        #expect(first == expectedFirst)
        #expect(second == expectedSecond)
        var disarmed = try Self.session([Self.keys], sensing: Self.policy())
        _ = try Self.play(&disarmed, Self.activeSensing, at: 0)
        _ = try Self.play(&disarmed, Self.systemReset, at: 10)
        let silent = try disarmed.poll(at: Self.stamp(500))
        #expect(silent == Self.empty)
        let disarmedPhase = Self.phase(disarmed)
        #expect(disarmedPhase == unarmed)
    }

    @Test
    func midiInputSessionDetachLeavesOtherInputsAndTheirPedalsAlone() throws {
        var session = try Self.session(sensing: Self.policy())
        _ = try Self.play(&session, Self.noteOn(60))
        _ = try Self.play(&session, Self.noteOn(64), from: Self.pads)
        _ = try Self.play(&session, Self.sustain, from: Self.pads)
        _ = try Self.play(&session, Self.noteOn(40), from: Self.drone)
        let released = try session.detach(Self.keys)
        let expected = [Self.sentOff(Self.piano, 60)]
        #expect(released == expected)
        let heldInputs = session.ledger.notes.map(\.input)
        #expect(heldInputs == [Self.pads, Self.drone])
        let holders = session.ledger.pedalHolds.map(\.input)
        #expect(holders == [Self.pads])
    }

    @Test
    func midiInputSessionRepeatedTriggersReleaseNothingTwice() throws {
        let sensing = try Self.policy()
        var session = try Self.session([Self.keys], sensing: sensing)
        _ = try Self.play(&session, Self.noteOn(60))
        let first = try session.detach(Self.keys)
        let expected = [Self.sentOff(Self.piano, 60)]
        #expect(first == expected)
        try session.register(Self.keys, key: Self.key(Self.keys), sensing: sensing)
        let second = try session.detach(Self.keys)
        #expect(second.isEmpty)
        var resetting = try Self.session([Self.keys])
        _ = try Self.play(&resetting, Self.noteOn(60))
        let firstReset = try resetting.resetSource(Self.keys)
        let secondReset = try resetting.resetSource(Self.keys)
        #expect(firstReset == expected)
        #expect(secondReset.isEmpty)
        let resetProfile = try Self.profile(reset: .resetSource)
        var flooded = try Self.session([Self.keys], profile: resetProfile)
        _ = try Self.play(&flooded, Self.noteOn(60))
        let flood = try Self.play(&flooded, Self.systemReset + Self.systemReset)
        let expectedFlood = Self.result(expected, notices: [.systemReset(Self.keys), .systemReset(Self.keys)])
        #expect(flood == expectedFlood)
    }

    @Test
    func midiInputSessionLossLeavesTheRegistryAndAnswersALateNoteOffAsUnowned() throws {
        var session = try Self.armedWithKeyHeld()
        let registryBefore = session.registry.snapshot
        _ = try session.poll(at: Self.stamp(200))
        let registryAfter = session.registry.snapshot
        #expect(registryAfter == registryBefore)
        let registryHeld = Self.held(session)
        #expect(registryHeld == [60])
        let late = try Self.play(&session, Self.noteOff(60), at: 300)
        let unowned = MIDIInputSessionRejection.ledger(.unownedNote(input: Self.keys, channel: 1, note: 60))
        let expected = Self.result(rejections: [unowned])
        #expect(late == expected)
        var phantom = try Self.armedWithKeyHeld(heldNotes: 1)
        _ = try phantom.poll(at: Self.stamp(200))
        let blocked = try Self.play(&phantom, Self.noteOn(62), at: 300)
        let limit = MIDIInputSessionRejection.state(.heldNoteLimit(channel: 1, note: 62))
        let expectedBlocked = Self.result(rejections: [limit])
        #expect(blocked == expectedBlocked)
        _ = try phantom.resetSource(Self.keys)
        let freed = try Self.play(&phantom, Self.noteOn(62), at: 400)
        let expectedFreed = Self.result([Self.sentOn(Self.piano, 62, 100)])
        #expect(freed == expectedFreed)
    }

    @Test
    func midiInputSessionRegressedStampIsRefusedWithoutAnyChange() throws {
        var session = try Self.session([Self.keys], sensing: Self.policy())
        _ = try Self.play(&session, Self.activeSensing, at: 50)
        let before = Self.Snapshot(session)
        let regressed = ActiveSensingRefusal.tickRegressed(last: 50, found: 40)
        let expected: MIDIInputSessionRefusal? = .sensing(input: Self.keys, reason: regressed)
        let refused = try Self.refusedFeed(&session, [0xB0, 7, 100], at: 40)
        #expect(refused == expected)
        let after = Self.Snapshot(session)
        #expect(after == before)
        var probe = try Self.session([Self.keys], sensing: Self.policy())
        let pending = try Self.play(&probe, [0x90, 60], at: 50)
        #expect(pending == Self.empty)
        let again = try Self.refusedFeed(&probe, [0xB0, 7, 100], at: 40)
        #expect(again == expected)
        let completed = try Self.play(&probe, [100], at: 50)
        let expectedCompleted = Self.result([Self.sentOn(Self.piano, 60, 100)])
        #expect(completed == expectedCompleted)
    }

    @Test
    func midiInputSessionDeadlineOverflowIsRefusedWithoutAnyChange() throws {
        let timeout: UInt64 = 1 << 48
        let edge = UInt64.max - timeout
        var accepted = try Self.session([Self.keys], sensing: Self.policy(timeout: timeout))
        let armed = try Self.play(&accepted, Self.activeSensing, at: edge)
        #expect(armed == Self.empty)
        let atMaximum = ActiveSensingPhase.armed(deadline: UInt64.max)
        let acceptedPhase = Self.phase(accepted)
        #expect(acceptedPhase == atMaximum)
        let overflow: MIDIInputSessionRefusal? = .sensing(input: Self.keys, reason: .deadlineOverflow)
        for ticks in [edge + 1, UInt64.max] {
            var fresh = try Self.session([Self.keys], sensing: Self.policy(timeout: timeout))
            let before = Self.Snapshot(fresh)
            let refused = try Self.refusedFeed(&fresh, Self.activeSensing, at: ticks)
            #expect(refused == overflow)
            let after = Self.Snapshot(fresh)
            #expect(after == before)
        }
        var partial = try Self.session([Self.keys], sensing: Self.policy(timeout: timeout))
        let whole = try Self.refusedFeed(&partial, [0x90, 0xFE], at: UInt64.max)
        #expect(whole == overflow)
        let observer = try #require(partial.observer(of: Self.keys))
        #expect(observer.lastTick == nil)
    }

    @Test
    func midiInputSessionFeedRefusalOrderIsPinned() throws {
        var session = try Self.session([Self.keys, Self.pads], sensing: Self.policy(), maximumFeedBytes: 8)
        let oversize = Array(repeating: UInt8(0xF8), count: 9)
        let unknown = try Self.refusedFeed(&session, oversize, from: Self.drone, at: 0)
        let expectedUnknown: MIDIInputSessionRefusal? = .source(.unknownInput(Self.drone))
        #expect(unknown == expectedUnknown)
        // An input that sorts below every registered one is unknown too, whatever the size of its packet.
        let below = MIDIInputID(0)
        let unknownBelow = try Self.refusedFeed(&session, oversize, from: below, at: 0)
        let expectedBelow: MIDIInputSessionRefusal? = .source(.unknownInput(below))
        #expect(unknownBelow == expectedBelow)
        _ = try Self.play(&session, Self.activeSensing, at: 50)
        let large = try Self.refusedFeed(&session, oversize, at: 40)
        let expectedLarge: MIDIInputSessionRefusal? = .source(.feedTooLarge(count: 9, limit: 8))
        #expect(large == expectedLarge)
        _ = try Self.play(&session, Self.activeSensing, from: Self.pads, at: 70)
        let regressed = ActiveSensingRefusal.tickRegressed(last: 50, found: 40)
        let expectedPoll: MIDIInputSessionRefusal? = .sensing(input: Self.keys, reason: regressed)
        let early = Self.stamp(40)
        let polled = Self.refusal { () throws(MIDIInputSessionRefusal) in try session.poll(at: early) }
        #expect(polled == expectedPoll)
    }

    @Test
    func midiInputSessionFeedSizeEdgesAndEmptyFeed() throws {
        var session = try Self.session([Self.keys], sensing: Self.policy(), maximumFeedBytes: 8)
        let eight: [UInt8] = [0x90, 60, 100, 0x80, 60, 64, 0xF8, 0xF8]
        let fed = try Self.play(&session, eight, at: 50)
        let expected = Self.result([Self.sentOn(Self.piano, 60, 100), Self.sentOff(Self.piano, 60)])
        #expect(fed == expected)
        // Tick 40 is behind the observer's last tick, so only the size check can name this refusal.
        let refused = try Self.refusedFeed(&session, eight + [0xF8], at: 40)
        let expectedRefusal: MIDIInputSessionRefusal? = .source(.feedTooLarge(count: 9, limit: 8))
        #expect(refused == expectedRefusal)
        let nothing = try Self.play(&session, [], at: 40)
        #expect(nothing == Self.empty)
        let observer = try #require(session.observer(of: Self.keys))
        #expect(observer.lastTick == 50)
    }

    @Test
    func midiInputSessionPollIsAtomicAndAscending() throws {
        var session = try Self.session([Self.keys, Self.pads], sensing: Self.policy())
        _ = try Self.play(&session, [0xFE, 0x90, 60, 100], at: 0)
        _ = try Self.play(&session, Self.activeSensing, from: Self.pads, at: 500)
        let before = Self.Snapshot(session)
        let regressed = ActiveSensingRefusal.tickRegressed(last: 500, found: 100)
        let expected: MIDIInputSessionRefusal? = .sensing(input: Self.pads, reason: regressed)
        let early = Self.stamp(100)
        let refused = Self.refusal { () throws(MIDIInputSessionRefusal) in try session.poll(at: early) }
        #expect(refused == expected)
        let after = Self.Snapshot(session)
        #expect(after == before)
        let observer = try #require(session.observer(of: Self.keys))
        #expect(observer.lastTick == 0)
        let stillHeld = session.ledger.notes.map(\.note)
        #expect(stillHeld == [60])
        var crossed = try Self.session([Self.pads, Self.keys], sensing: Self.policy())
        _ = try Self.play(&crossed, [0xFE, 0x90, 60, 100], at: 0)
        _ = try Self.play(&crossed, [0xFE, 0x90, 62, 100], from: Self.pads, at: 0)
        let lost = try crossed.poll(at: Self.stamp(100))
        let expectedLost = Self.result(
            [Self.sentOff(Self.piano, 60), Self.sentOff(Self.strings, 62)],
            notices: [.sensingLostReleased(Self.keys), .sensingLostReleased(Self.pads)]
        )
        #expect(lost == expectedLost)
        var quiet = try Self.session([Self.keys])
        let first = try quiet.poll(at: Self.stamp(0))
        let last = try quiet.poll(at: Self.stamp(UInt64.max))
        #expect(first == Self.empty)
        #expect(last == Self.empty)
    }

    // MARK: - Loss and System Reset, the pedal, System Exclusive, limits

    @Test
    func midiInputSessionLossAndSystemResetInOnePacketKeepTheirOrder() throws {
        var session = try Self.armedWithKeyHeld(reset: .resetSource)
        let packet = try Self.play(&session, Self.noteOn(62) + Self.systemReset, at: 300)
        // The loss is found at the packet's first byte, so its release comes first; the reset releases at its place.
        let expected = Self.result(
            [Self.sentOff(Self.piano, 60), Self.sentOn(Self.piano, 62, 100), Self.sentOff(Self.piano, 62)],
            notices: [.sensingLostReleased(Self.keys), .systemReset(Self.keys)]
        )
        #expect(packet == expected)
        let stillHeld = session.ledger.notes.map(\.note)
        #expect(stillHeld.isEmpty)
        let unarmed = ActiveSensingPhase.unarmed
        let phase = Self.phase(session)
        #expect(phase == unarmed)
    }

    @Test
    func midiInputSessionDetachReleasesKeysThenThePedalAndLeavesNoHold() throws {
        var session = try Self.session([Self.keys])
        _ = try Self.play(&session, Self.noteOn(60))
        _ = try Self.play(&session, Self.sustain)
        let holders = session.ledger.pedalHolds.map(\.input)
        #expect(holders == [Self.keys])
        let released = try session.detach(Self.keys)
        let expected = [Self.sentOff(Self.piano, 60), Self.sentSustainUp(Self.piano)]
        #expect(released == expected)
        let holds = session.ledger.pedalHolds
        #expect(holds.isEmpty)
        let notes = session.ledger.notes
        #expect(notes.isEmpty)
    }

    @Test
    func midiInputSessionPollLossReleasesKeysThenThePedalAndLeavesNoHold() throws {
        var session = try Self.armedWithKeyHeld()
        _ = try Self.play(&session, Self.sustain, at: 10)
        let holders = session.ledger.pedalHolds.map(\.input)
        #expect(holders == [Self.keys])
        let lost = try session.poll(at: Self.stamp(200))
        let expected = Self.result(
            [Self.sentOff(Self.piano, 60), Self.sentSustainUp(Self.piano)], notices: [.sensingLostReleased(Self.keys)]
        )
        #expect(lost == expected)
        let holds = session.ledger.pedalHolds
        #expect(holds.isEmpty)
        let notes = session.ledger.notes
        #expect(notes.isEmpty)
    }

    @Test
    func midiInputSessionSystemExclusiveEndedByALaterPacketKeepsTheInputAlive() throws {
        var session = try Self.armedWithKeyHeld()
        let opened = try Self.play(&session, [0xF0, 0x01, 0x02], at: 100)
        #expect(opened == Self.empty)
        let ended = try Self.play(&session, [0xF7], at: 150)
        #expect(ended == Self.empty)
        let refreshed = ActiveSensingPhase.armed(deadline: 250)
        let phase = Self.phase(session)
        #expect(phase == refreshed)
        // Without the End Of Exclusive byte the deadline would still be 200.
        let alive = try session.poll(at: Self.stamp(200))
        #expect(alive == Self.empty)
        let lost = try session.poll(at: Self.stamp(250))
        let expected = Self.result([Self.sentOff(Self.piano, 60)], notices: [.sensingLostReleased(Self.keys)])
        #expect(lost == expected)
        let lostPhase = ActiveSensingPhase.lost(since: 250)
        let afterLoss = Self.phase(session)
        #expect(afterLoss == lostPhase)
    }

    @Test
    func midiInputSessionMakeAcceptsTheLimitsAtBothEdges() throws {
        let widest = try MIDIInputSession.make(maximumSources: 128, maximumFeedBytes: 65_536)
        let widestSources = widest.registry.maximumSources
        let widestFeed = widest.registry.maximumFeedBytes
        #expect(widestSources == 128)
        #expect(widestFeed == 65_536)
        let narrowest = try MIDIInputSession.make(maximumSources: 1, maximumFeedBytes: 1)
        let narrowestSources = narrowest.registry.maximumSources
        let narrowestFeed = narrowest.registry.maximumFeedBytes
        #expect(narrowestSources == 1)
        #expect(narrowestFeed == 1)
        // One above the feed limit is refused on its own, not only beside a refused source limit.
        let tooWide = Self.refusal { () throws(MIDIInputSessionRefusal) in
            try MIDIInputSession.make(maximumSources: 128, maximumFeedBytes: 65_537)
        }
        let expectedRefusal: MIDIInputSessionRefusal? = .source(.invalidConfiguration(.maximumFeedBytes))
        #expect(tooWide == expectedRefusal)
    }
}
