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

        let unknown = Fx.lostRefusal(&spare, Fx.nineInput)
        let afterSpare = spare
        #expect(unknown == .unknownInput(Fx.nineInput))
        #expect(spare == afterSpare)
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
}
