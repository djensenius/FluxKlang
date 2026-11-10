import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlInputBankTests.Fx {
    /// `bnd.a` on cc71 and `bnd.b` on cc70 (id order differs from source order), `bnd.c` on the other input, a
    /// momentary trigger `bnd.t` on cc80 and a toggle `bnd.g` on cc82.
    static func lossBank() throws -> ControlInputBank {
        try ControlInputBank(
            links: links(),
            faders: [fader("bnd.a", source: pad71), fader("bnd.b", pickup: .catch), fader("bnd.c", source: slider7)],
            triggers: [trigger("bnd.t"), trigger("bnd.g", source: pad82, mode: .toggle)]
        )
    }

    static func originLinks(_ count: Int) throws -> [ControlInputBankLink] {
        try (1...count).map { index in
            try ControlInputBankLink(input: MIDIInputID(UInt32(index)), origin: origin("ib-link-\(index)"))
        }
    }

    /// A jump fader `bnd.a`, a momentary trigger `bnd.t` on cc80, a latch `bnd.l` on cc82 and a toggle `bnd.g` on the
    /// other input's cc81.
    static func clearBank() throws -> ControlInputBank {
        try ControlInputBank(
            links: links(), faders: [fader("bnd.a")],
            triggers: [trigger("bnd.t"), trigger("bnd.l", source: pad82, mode: .latch),
                       trigger("bnd.g", source: slider81, mode: .toggle)]
        )
    }

    static func clearRefusal(_ bank: inout ControlInputBank, _ id: String) throws -> ControlInputBankRefusal? {
        let binding = try BindingID(id)
        do throws(ControlInputBankRefusal) {
            _ = try bank.clear(binding)
            return nil
        } catch {
            return error
        }
    }
}

extension ControlInputBankTests {
    @Test
    func controlInputBankBuildRefusesLinkDefectsInOrder() throws {
        let limit = 128
        let pinned = ControlInputBank.maximumLinks == limit
        let tied = ControlInputBank.maximumLinks == ControlSourceAvailability.maximumLiveOrigins
        #expect(pinned)
        #expect(tied)
        let accepted = Fx.buildRefusal(links: try Fx.originLinks(limit))
        #expect(accepted == nil)
        let tooMany = Fx.buildRefusal(links: try Fx.originLinks(limit + 1))
        #expect(tooMany == .tooManyLinks(limit + 1))

        let pad = try Fx.origin("ib-pad")
        let other = try Fx.origin("ib-other")
        let twoInputs = try [
            ControlInputBankLink(input: MIDIInputID(5), origin: Fx.origin("ib-a")),
            ControlInputBankLink(input: MIDIInputID(2), origin: Fx.origin("ib-b")),
            ControlInputBankLink(input: MIDIInputID(5), origin: Fx.origin("ib-c")),
            ControlInputBankLink(input: MIDIInputID(2), origin: Fx.origin("ib-d"))
        ]
        let duplicateInput = Fx.buildRefusal(links: twoInputs)
        #expect(duplicateInput == .duplicateInput(MIDIInputID(2)))

        let twoOrigins = [
            ControlInputBankLink(input: MIDIInputID(1), origin: pad),
            ControlInputBankLink(input: MIDIInputID(2), origin: other),
            ControlInputBankLink(input: MIDIInputID(3), origin: pad),
            ControlInputBankLink(input: MIDIInputID(4), origin: other)
        ]
        let duplicateOrigin = Fx.buildRefusal(links: twoOrigins)
        #expect(duplicateOrigin == .duplicateOrigin(other))

        let both = [
            ControlInputBankLink(input: MIDIInputID(1), origin: pad),
            ControlInputBankLink(input: MIDIInputID(1), origin: pad)
        ]
        let inputFirst = Fx.buildRefusal(links: both)
        #expect(inputFirst == .duplicateInput(MIDIInputID(1)))

        var crowded = try Fx.originLinks(limit + 1)
        crowded[1] = ControlInputBankLink(input: crowded[0].input, origin: crowded[1].origin)
        let countFirst = Fx.buildRefusal(links: crowded)
        #expect(countFirst == .tooManyLinks(limit + 1))
    }

    @Test
    func controlInputBankBuildRefusesTriggerCountAndBindingDefectsInOrder() throws {
        let limit = 256
        let pinned = ControlInputBank.maximumTriggers == limit
        #expect(pinned)
        let links = try Fx.links()
        let accepted = Fx.buildRefusal(links: links, triggers: try Fx.triggers(limit))
        #expect(accepted == nil)
        let tooMany = Fx.buildRefusal(links: links, triggers: try Fx.triggers(limit + 1))
        #expect(tooMany == .tooManyTriggers(limit + 1))

        let unmappable = try Fx.fader("bnd.u", source: ControlSourceID(validated: "ctl.pedal-1"))
        let unmappableRefusal = Fx.buildRefusal(links: links, faders: [unmappable])
        #expect(unmappableRefusal == .unmappableSource(unmappable.id))

        let stray = try Fx.fader("bnd.s", source: ControlSourceID(validated: "midi.ib-none.1.cc.7"))
        let strayRefusal = Fx.buildRefusal(links: links, faders: [stray])
        let none = try Fx.origin("ib-none")
        #expect(strayRefusal == .originNotLinked(stray.id, none))

        let countFirst = Fx.buildRefusal(links: links, faders: [unmappable], triggers: try Fx.triggers(limit + 1))
        #expect(countFirst == .tooManyTriggers(limit + 1))

        let badTrigger = try Fx.trigger("bnd.z", source: ControlSourceID(validated: "midi.ib-none.1.cc.80"))
        let faderFirst = Fx.buildRefusal(links: links, faders: [unmappable], triggers: [badTrigger])
        #expect(faderFirst == .unmappableSource(unmappable.id))
        let triggerRefusal = Fx.buildRefusal(links: links, triggers: [badTrigger])
        #expect(triggerRefusal == .originNotLinked(badTrigger.id, none))
    }

    @Test
    func controlInputBankBuildRefusesFaderCountAndBookAndDetectorDefects() throws {
        let limit = 256
        let pinned = ControlInputBank.maximumFaders == limit
        #expect(pinned)
        let links = try Fx.links()
        let accepted = Fx.buildRefusal(links: links, faders: try Fx.faders(limit))
        #expect(accepted == nil)
        var crowded = try Fx.faders(limit)
        try crowded.append(Fx.fader("bnd.z", source: ControlSourceID(validated: "ctl.pedal-1")))
        let tooMany = Fx.buildRefusal(links: links, faders: crowded)
        #expect(tooMany == .tooManyFaders(limit + 1))

        let repeated = try [
            Fx.fader("bnd.b"), Fx.fader("bnd.a"), Fx.fader("bnd.a"), Fx.fader("bnd.B"), Fx.fader("bnd.B")
        ]
        let duplicateFader = Fx.buildRefusal(links: links, faders: repeated)
        let capital = try BindingID("bnd.B")
        #expect(duplicateFader == .pickup(.duplicateBinding(capital)))

        let twin = try Fx.trigger("bnd.t")
        let duplicateTrigger = Fx.buildRefusal(links: links, triggers: [twin, twin])
        #expect(duplicateTrigger == .trigger(.duplicateBinding(twin.id)))
    }

    @Test
    func controlInputBankLossUnavailablesFadersInIdOrderAndReleasesHeldTriggers() throws {
        var bank = try Fx.lossBank()
        _ = try Fx.hear(&bank, 80)
        _ = try Fx.hear(&bank, 82)
        let loss = try bank.inputLost(Fx.padInput)
        #expect(loss.input == Fx.padInput)
        let pad = try Fx.origin("ib-pad")
        #expect(loss.origin == pad)
        #expect(Fx.names(loss.unavailable) == ["bnd.a", "bnd.b"])
        let release = try #require(loss.releases.first)
        #expect(loss.releases.count == 1)
        #expect(release.binding.rawValue == "bnd.t")
        #expect(release.action == .release)
        #expect(release.cause == .disconnect)
        #expect(release.sequence == 3)
        #expect(bank.detector.lastSequence == 3)

        let toggle = try BindingID("bnd.g")
        let toggleState = try #require(bank.detector.state(of: toggle))
        #expect(toggleState.isOn)
        let stateA = try bank.pickup.state(of: BindingID("bnd.a"))
        let stateB = try bank.pickup.state(of: BindingID("bnd.b"))
        let stateC = try bank.pickup.state(of: BindingID("bnd.c"))
        #expect(stateA == .unavailable)
        #expect(stateB == .unavailable)
        #expect(stateC == .engaged(hardware: nil))
        #expect(bank.lostInputs == [Fx.padInput])
    }

    @Test
    func controlInputBankLossOfOneInputLeavesTheOthersReceiving() throws {
        var bank = try Fx.bank()
        let sliderLoss = try bank.inputLost(Fx.sliderInput)
        #expect(Fx.names(sliderLoss.unavailable) == ["bnd.c"])
        let sliderSeen = try bank.inputSeen(Fx.sliderInput)
        #expect(Fx.names(sliderSeen) == ["bnd.c"])
        _ = try bank.inputLost(Fx.sliderInput)
        let result = try Fx.hear(&bank, 70)
        let proposed = result.faders.proposals.map(\.binding.rawValue)
        #expect(proposed == ["bnd.a"])
        #expect(bank.lostInputs == [Fx.sliderInput])

        var spare = try Fx.bank()
        let before = spare
        let spareLoss = try spare.inputLost(Fx.spareInput)
        #expect(spareLoss.unavailable.isEmpty)
        #expect(spareLoss.releases.isEmpty)
        #expect(spare.lostInputs == [Fx.spareInput])
        #expect(spare.pickup == before.pickup)

        let beforeUnknown = spare
        let unknown = Fx.lostRefusal(&spare, Fx.nineInput)
        #expect(unknown == .unknownInput(Fx.nineInput))
        #expect(spare == beforeUnknown)
    }

    @Test
    func controlInputBankRepeatedLossAndSeenOnALiveInputChangeNothing() throws {
        var bank = try Fx.lossBank()
        _ = try Fx.hear(&bank, 80)
        let first = try bank.inputLost(Fx.padInput)
        #expect(first.releases.count == 1)
        let afterFirst = bank
        let second = try bank.inputLost(Fx.padInput)
        #expect(second.unavailable.isEmpty)
        #expect(second.releases.isEmpty)
        #expect(bank == afterFirst)

        var live = try Fx.bank()
        let before = live
        let seen = try live.inputSeen(Fx.sliderInput)
        #expect(seen.isEmpty)
        #expect(live == before)
    }

    @Test
    func controlInputBankSeenReturnsTheFadersAndReopensTheOrigin() throws {
        var bank = try Fx.lossBank()
        let lost = try bank.inputLost(Fx.padInput)
        #expect(Fx.names(lost.unavailable) == ["bnd.a", "bnd.b"])
        let seen = try bank.inputSeen(Fx.padInput)
        #expect(Fx.names(seen) == ["bnd.a", "bnd.b"])
        let jumpState = try bank.pickup.state(of: BindingID("bnd.a"))
        let catchState = try bank.pickup.state(of: BindingID("bnd.b"))
        #expect(jumpState == .engaged(hardware: nil))
        #expect(catchState == .waiting(hardware: nil))
        #expect(bank.lostInputs.isEmpty)
        let result = try Fx.hear(&bank, 71)
        let proposed = result.faders.proposals.map(\.binding.rawValue)
        #expect(proposed == ["bnd.a"])

        let unknown = Fx.seenRefusal(&bank, Fx.nineInput)
        #expect(unknown == .unknownInput(Fx.nineInput))
    }

    @Test
    func controlInputBankBuildOrderPicksTheEarlierStepForEachPairOfDefects() throws {
        let links = try Fx.links()
        let badTrigger = try Fx.trigger("bnd.z", source: ControlSourceID(validated: "midi.ib-none.1.cc.80"))
        let ghost = try Fx.origin("ib-none")

        let bothCounts = Fx.buildRefusal(links: links, faders: try Fx.faders(257), triggers: try Fx.triggers(257))
        #expect(bothCounts == .tooManyFaders(257))

        let pad = try Fx.origin("ib-pad")
        let twice = [
            ControlInputBankLink(input: MIDIInputID(1), origin: pad),
            ControlInputBankLink(input: MIDIInputID(1), origin: pad)
        ]
        let linkFirst = Fx.buildRefusal(links: twice, faders: try Fx.faders(257), triggers: try Fx.triggers(257))
        #expect(linkFirst == .duplicateInput(MIDIInputID(1)))

        let stray = try Fx.fader("bnd.a", source: ControlSourceID(validated: "midi.ib-none.1.cc.7"))
        let attachFirst = try Fx.buildRefusal(links: links, faders: [Fx.fader("bnd.a"), stray])
        #expect(attachFirst == .originNotLinked(stray.id, ghost))

        let twin = try [Fx.fader("bnd.a"), Fx.fader("bnd.a")]
        let faderFirst = Fx.buildRefusal(links: links, faders: twin, triggers: [badTrigger])
        let first = try BindingID("bnd.a")
        #expect(faderFirst == .pickup(.duplicateBinding(first)))

        let same = try Fx.trigger("bnd.t")
        let attachBeforeDetector = Fx.buildRefusal(links: links, triggers: [badTrigger, same, same])
        #expect(attachBeforeDetector == .originNotLinked(badTrigger.id, ghost))
    }

    @Test
    func controlInputBankClearSwitchesALatchOffOnceAndLeavesTheBankEqualWhenAlreadyOff() throws {
        var bank = try Fx.clearBank()
        let press = try Fx.hear(&bank, 82)
        let switchedOn = try #require(press.triggers.commands.first)
        #expect(switchedOn.binding.rawValue == "bnd.l")
        #expect(switchedOn.action == .switchedOn)
        #expect(switchedOn.sequence == 1)

        let off = try #require(try bank.clear(BindingID("bnd.l")))
        #expect(off.binding.rawValue == "bnd.l")
        #expect(off.target == Fx.fire)
        #expect(off.source == Fx.pad82)
        #expect(off.action == .switchedOff)
        #expect(off.cause == .clear)
        #expect(off.sequence == 2)
        #expect(bank.detector.lastSequence == 2)

        let snapshot = bank
        let again = try bank.clear(BindingID("bnd.l"))
        #expect(again == nil)
        #expect(bank == snapshot)
        #expect(bank.detector.lastSequence == 2)
    }

    @Test
    func controlInputBankClearRefusesMomentaryUnknownAndFaderIDsAsTriggerRefusals() throws {
        var bank = try Fx.clearBank()
        _ = try Fx.hear(&bank, 82)
        let cases: [(String, ControlTriggerRefusal)] = try [
            ("bnd.t", .notClearable(.momentary)),
            ("bnd.zz", .unknownBinding(BindingID("bnd.zz"))),
            ("bnd.a", .unknownBinding(BindingID("bnd.a")))
        ]
        for (id, detail) in cases {
            let snapshot = bank
            let refusal = try Fx.clearRefusal(&bank, id)
            #expect(refusal == .trigger(detail))
            #expect(bank == snapshot)
        }
    }

    @Test
    func controlInputBankClearStillSwitchesALatchOffAfterItsOriginIsLost() throws {
        var bank = try Fx.clearBank()
        _ = try Fx.hear(&bank, 82)
        let loss = try bank.inputLost(Fx.padInput)
        #expect(loss.releases.isEmpty)
        #expect(bank.detector.lastSequence == 1)
        #expect(bank.lostInputs == [Fx.padInput])

        let off = try #require(try bank.clear(BindingID("bnd.l")))
        #expect(off.action == .switchedOff)
        #expect(off.cause == .clear)
        #expect(off.sequence == 2)
        #expect(bank.lostInputs == [Fx.padInput])
    }

    @Test
    func controlInputBankClearKeepsTheHeldFlagSoThePressAfterItNeedsARelease() throws {
        var bank = try Fx.clearBank()
        _ = try Fx.hear(&bank, 82)
        _ = try bank.clear(BindingID("bnd.l"))
        let stillHeld = try Fx.hear(&bank, 82)
        #expect(stillHeld.triggers.commands.isEmpty)
        let released = try Fx.hear(&bank, 82, 0)
        #expect(released.triggers.commands.isEmpty)
        let pressed = try Fx.hear(&bank, 82)
        let command = try #require(pressed.triggers.commands.first)
        #expect(command.action == .switchedOn)
        #expect(command.sequence == 3)
    }

    @Test
    func controlInputBankClearSwitchesAToggleOffAndTheNextPressSwitchesItOn() throws {
        var bank = try Fx.clearBank()
        let press = try Fx.hear(&bank, 81, origin: "ib-fader")
        let switchedOn = try #require(press.triggers.commands.first)
        #expect(switchedOn.action == .switchedOn)
        let off = try #require(try bank.clear(BindingID("bnd.g")))
        #expect(off.action == .switchedOff)
        #expect(off.cause == .clear)
        #expect(off.source == Fx.slider81)
        #expect(off.sequence == 2)
        _ = try Fx.hear(&bank, 81, 0, origin: "ib-fader")
        let again = try Fx.hear(&bank, 81, origin: "ib-fader")
        let command = try #require(again.triggers.commands.first)
        #expect(command.action == .switchedOn)
        #expect(command.sequence == 3)
    }
}
