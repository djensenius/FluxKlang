import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Control input bank (#87, CPR1): one pickup book and one trigger detector behind `receive`, joined to a MIDI input
/// through `inputLost` and `inputSeen`. This file holds the fixtures and the `receive` and build tests; `+Lifecycle`
/// holds the link, loss and return tests. Every fixture is nested in `Fx`, so no name leaves the suite.
#if os(macOS)
@Suite("Control input bank", .productionAccessAudit)
#else
@Suite("Control input bank")
#endif
struct ControlInputBankTests {
    // swiftlint:disable:next type_name
    enum Fx {
        static let level = ParameterID(validated: "par.ib.level")
        static let hazard = ParameterID(validated: "par.ib.hazard")
        static let fire = ControlTriggerTargetID(validated: "trg.ib.fire")
        static let danger = ControlTriggerTargetID(validated: "trg.ib.hazard")
        static let pad70 = ControlSourceID(validated: "midi.ib-pad.1.cc.70")
        static let pad71 = ControlSourceID(validated: "midi.ib-pad.1.cc.71")
        static let pad80 = ControlSourceID(validated: "midi.ib-pad.1.cc.80")
        static let pad82 = ControlSourceID(validated: "midi.ib-pad.1.cc.82")
        static let slider7 = ControlSourceID(validated: "midi.ib-fader.1.cc.7")
        static let slider81 = ControlSourceID(validated: "midi.ib-fader.1.cc.81")
        static let padInput = MIDIInputID(1)
        static let sliderInput = MIDIInputID(2)
        static let spareInput = MIDIInputID(3)
        static let nineInput = MIDIInputID(9)

        static func origin(_ token: String) throws -> ControlSourceOrigin { try ControlSourceOrigin(token) }

        static func links() throws -> [ControlInputBankLink] {
            try [
                ControlInputBankLink(input: padInput, origin: origin("ib-pad")),
                ControlInputBankLink(input: sliderInput, origin: origin("ib-fader")),
                ControlInputBankLink(input: spareInput, origin: origin("ib-spare"))
            ]
        }

        static func fader(_ id: String, source: ControlSourceID = pad70, target: ParameterID = level,
                          pickup: PickupMode = .jump) throws -> ControlBinding {
            try ControlBinding(.init(
                id: BindingID(id), source: source, target: target, unit: .percent,
                profile: .absolute(resolution: 128), upper: nil, pickup: pickup
            ))
        }

        static func trigger(_ id: String, source: ControlSourceID = pad80, mode: ControlTriggerMode = .momentary,
                            target: ControlTriggerTargetID = fire) throws -> ControlTriggerBinding {
            try ControlTriggerBinding(ControlTriggerBindingFields(
                id: BindingID(id), source: source, target: target, profile: .absolute(resolution: 128),
                mode: mode, pressAt: 0.5, releaseAt: 0.25, emitsRelease: mode == .momentary ? true : nil
            ))
        }

        /// A jump fader, a catch fader on the same controller and a fader on the other input; one momentary trigger.
        static func bank(after sequence: UInt64 = 0) throws -> ControlInputBank {
            try ControlInputBank(
                links: links(),
                faders: [fader("bnd.a"), fader("bnd.b", pickup: .catch), fader("bnd.c", source: slider7)],
                triggers: [trigger("bnd.t")], afterSequence: sequence
            )
        }

        static func descriptor(_ id: ParameterID, _ kind: ControlClass) throws -> ParameterDescriptor {
            try ParameterDescriptor(.init(
                id: id, unit: .percent, lower: 0, upper: 100, defaultValue: 0, ceiling: nil, curve: .linear,
                ramp: .step, controlClass: kind, verification: .unverified
            ))
        }

        /// The parameter `level` is live at `host` percent; `hazard` is hazardous; `fire` is live; `danger` is not.
        static func truth(host: Double = 50) throws -> ControlInputBankTruth {
            let catalog = try ParameterCatalog([descriptor(level, .live), descriptor(hazard, .hazardous)])
            let values = [
                level: ParameterValue(value: host, unit: .percent),
                hazard: ParameterValue(value: 10, unit: .percent)
            ]
            let control = try ControlHostTruth(catalog: catalog, values: values)
            let sources: Set<ControlSourceID> = [pad80, pad82, slider81]
            let trigger = try ControlTriggerHostTruth(sources: sources, targets: [fire: .live, danger: .hazardous])
            return ControlInputBankTruth(control: control, trigger: trigger)
        }

        static func input(_ number: UInt8, _ value: UInt8 = 127, origin token: String = "ib-pad") throws
            -> ControlLocalInput {
            try ControlLocalInput(
                update: MIDI1StateUpdate(channel: 1, effect: .controller(number, value: value)),
                origin: origin(token)
            )
        }

        static func hear(_ bank: inout ControlInputBank, _ number: UInt8, _ value: UInt8 = 127,
                         origin token: String = "ib-pad", learn: LearnPhaseKind = .idle,
                         echoes: Set<BindingID> = []) throws -> ControlInputBankResult {
            let heard = try input(number, value, origin: token)
            let host = try truth()
            return try bank.receive(heard, learn: learn, echoes: echoes, truth: host)
        }

        static func refused(_ bank: inout ControlInputBank, _ number: UInt8,
                            origin token: String = "ib-pad") throws -> ControlInputBankRefusal? {
            let heard = try input(number, origin: token)
            let host = try truth()
            do throws(ControlInputBankRefusal) {
                _ = try bank.receive(heard, learn: .idle, echoes: [], truth: host)
                return nil
            } catch {
                return error
            }
        }

        static func lostRefusal(_ bank: inout ControlInputBank, _ input: MIDIInputID) -> ControlInputBankRefusal? {
            do throws(ControlInputBankRefusal) {
                _ = try bank.inputLost(input)
                return nil
            } catch {
                return error
            }
        }

        static func seenRefusal(_ bank: inout ControlInputBank, _ input: MIDIInputID) -> ControlInputBankRefusal? {
            do throws(ControlInputBankRefusal) {
                _ = try bank.inputSeen(input)
                return nil
            } catch {
                return error
            }
        }

        static func buildRefusal(links: [ControlInputBankLink], faders: [ControlBinding] = [],
                                 triggers: [ControlTriggerBinding] = []) -> ControlInputBankRefusal? {
            do throws(ControlInputBankRefusal) {
                _ = try ControlInputBank(links: links, faders: faders, triggers: triggers)
                return nil
            } catch {
                return error
            }
        }

        static func names(_ ids: [BindingID]) -> [String] { ids.map(\.rawValue) }

        static func padded(_ prefix: String, _ index: Int) -> String {
            let digits = String(index)
            return prefix + String(repeating: "0", count: 4 - digits.count) + digits
        }

        static func paddedIDs(_ prefix: String, _ count: Int) -> [String] {
            (0..<count).map { padded(prefix, $0) }
        }

        static func faders(_ count: Int, source: ControlSourceID = pad70) throws -> [ControlBinding] {
            try paddedIDs("bnd.f", count).map { try fader($0, source: source) }
        }

        static func triggers(_ count: Int) throws -> [ControlTriggerBinding] {
            try paddedIDs("bnd.n", count).map { try trigger($0) }
        }
    }

    @Test
    func controlInputBankGoldenReceiveRecordsFaderStateAndFiresTheTrigger() throws {
        var bank = try Fx.bank()
        let before = bank
        let first = try Fx.hear(&bank, 70)
        let jump = try BindingID("bnd.a")
        let held = try BindingID("bnd.b")
        let proposal = try #require(first.faders.proposals.first)
        let hold = try #require(first.faders.holds.first)
        #expect(first.faders.proposals.count == 1)
        #expect(proposal.binding == jump)
        #expect(proposal.target == Fx.level)
        let operation = CommandOperation.set(Fx.level, ParameterValue(value: 100, unit: .percent))
        #expect(proposal.operation == operation)
        #expect(first.faders.holds.count == 1)
        #expect(hold.binding == held)
        #expect(hold.hardware == 1)
        #expect(hold.target == 0.5)
        #expect(hold.reason == .notCaught)
        let updated = first.faders.pickupUpdates.map(\.binding.rawValue)
        #expect(updated == ["bnd.a", "bnd.b"])
        let jumpState = bank.pickup.state(of: jump)
        let heldState = bank.pickup.state(of: held)
        #expect(jumpState == .engaged(hardware: 1))
        #expect(heldState == .waiting(hardware: 1))
        #expect(first.triggers.commands.isEmpty)
        #expect(bank.detector == before.detector)

        let bookAfterFader = bank.pickup
        let second = try Fx.hear(&bank, 80)
        let command = try #require(second.triggers.commands.first)
        #expect(second.triggers.commands.count == 1)
        #expect(command.binding.rawValue == "bnd.t")
        #expect(command.action == .press)
        #expect(command.cause == .input)
        #expect(command.sequence == 1)
        #expect(second.faders.pickupUpdates.isEmpty)
        #expect(bank.pickup == bookAfterFader)
        #expect(bank.detector.lastSequence == 1)
    }

    @Test
    func controlInputBankEchoedFaderIsNotRecorded() throws {
        var bank = try Fx.bank()
        let jump = try BindingID("bnd.a")
        let result = try Fx.hear(&bank, 70, echoes: [jump])
        #expect(result.faders.echoed == [jump])
        let proposed = result.faders.proposals.map(\.binding.rawValue)
        #expect(proposed.isEmpty)
        let updated = result.faders.pickupUpdates.map(\.binding.rawValue)
        #expect(updated == ["bnd.b"])
        let echoedState = bank.pickup.state(of: jump)
        #expect(echoedState == .engaged(hardware: nil))
    }

    @Test
    func controlInputBankSecondReceiveReadsTheStoredCatchState() throws {
        var bank = try Fx.bank()
        let held = try BindingID("bnd.b")
        _ = try Fx.hear(&bank, 70)
        let storedState = bank.pickup.state(of: held)
        #expect(storedState == .waiting(hardware: 1))
        let second = try Fx.hear(&bank, 70, 0)
        let proposed = second.faders.proposals.map(\.binding.rawValue)
        #expect(proposed == ["bnd.a", "bnd.b"])
        #expect(second.faders.holds.isEmpty)
        let caught = bank.pickup.state(of: held)
        #expect(caught == .engaged(hardware: 0))
    }

    @Test
    func controlInputBankLearnRefusesBothPathsAndLeavesTheBankEqual() throws {
        var bank = try Fx.bank()
        for kind in [LearnPhaseKind.listening, LearnPhaseKind.awaitingReview] {
            let before = bank
            let fader = try Fx.hear(&bank, 70, learn: kind)
            let pad = try Fx.hear(&bank, 80, learn: kind)
            #expect(fader.faders.refusals == [.learnActive(kind)])
            #expect(fader.triggers.refusals == [.learnActive(kind)])
            #expect(pad.faders.refusals == [.learnActive(kind)])
            #expect(pad.triggers.refusals == [.learnActive(kind)])
            #expect(bank == before)
            #expect(bank.detector.lastSequence == 0)
        }
        for kind in [LearnPhaseKind.idle, .committed, .cancelled, .blocked] {
            var fresh = try Fx.bank()
            let result = try Fx.hear(&fresh, 70, learn: kind)
            let proposed = result.faders.proposals.map(\.binding.rawValue)
            #expect(proposed == ["bnd.a"])
            #expect(result.faders.refusals.isEmpty)
            #expect(result.triggers.refusals.isEmpty)
        }
    }

    @Test
    func controlInputBankRefusedReceiveLeavesTheBankEqual() throws {
        var bank = try Fx.bank()
        let before = bank
        let unlinked = try Fx.refused(&bank, 70, origin: "ib-other")
        let other = try Fx.origin("ib-other")
        #expect(unlinked == .unlinkedOrigin(other))
        #expect(bank == before)

        _ = try bank.inputLost(Fx.padInput)
        let lostBank = bank
        let pad = try Fx.origin("ib-pad")
        let fromFader = try Fx.refused(&bank, 70)
        let fromTrigger = try Fx.refused(&bank, 80)
        #expect(fromFader == .originLost(pad))
        #expect(fromTrigger == .originLost(pad))
        #expect(bank == lostBank)
        #expect(bank.detector.lastSequence == 0)
    }

    @Test
    func controlInputBankPassesThroughHazardousFaderAndTriggerRefusals() throws {
        let hazardFader = try Fx.fader("bnd.h", source: Fx.pad71, target: Fx.hazard)
        let triggers = try [Fx.trigger("bnd.t"), Fx.trigger("bnd.x", target: Fx.danger)]
        var bank = try ControlInputBank(links: Fx.links(), faders: [hazardFader], triggers: triggers)
        let faderResult = try Fx.hear(&bank, 71)
        let hazardID = try BindingID("bnd.h")
        let expected = ControlLocalDispatchRefusal.binding(hazardID, .unboundableClass(.hazardous))
        #expect(faderResult.faders.refusals == [expected])
        #expect(faderResult.faders.proposals.isEmpty)
        let faderState = bank.pickup.state(of: hazardID)
        #expect(faderState == .engaged(hardware: nil))

        let padResult = try Fx.hear(&bank, 80)
        let blocked = try BindingID("bnd.x")
        let refusal = ControlLocalTriggerRefusal.detector(blocked, .targetClass(Fx.danger, .hazardous))
        #expect(padResult.triggers.refusals == [refusal])
        let fired = padResult.triggers.commands.map(\.binding.rawValue)
        #expect(fired == ["bnd.t"])
    }

    @Test
    func controlInputBankLimitsAtWorkAndTheirRelationToTheBindingCaps() throws {
        let faderCount = 256
        let triggerCount = 256
        let pinnedFaders = ControlInputBank.maximumFaders == faderCount
        let pinnedTriggers = ControlInputBank.maximumTriggers == triggerCount
        #expect(pinnedFaders)
        #expect(pinnedTriggers)
        var bank = try ControlInputBank(
            links: Fx.links(), faders: Fx.faders(faderCount), triggers: Fx.triggers(triggerCount)
        )
        let result = try Fx.hear(&bank, 70)
        let proposed = result.faders.proposals.map(\.binding.rawValue)
        let updated = result.faders.pickupUpdates.map(\.binding.rawValue)
        let faderIDs = Fx.paddedIDs("bnd.f", faderCount)
        #expect(proposed == faderIDs)
        #expect(updated == faderIDs)
        let lastID = try BindingID(Fx.padded("bnd.f", faderCount - 1))
        let lastState = bank.pickup.state(of: lastID)
        #expect(lastState == .engaged(hardware: 1))

        let pressed = try Fx.hear(&bank, 80)
        let sequences = pressed.triggers.commands.map(\.sequence)
        let wanted = (1...triggerCount).map { UInt64($0) }
        #expect(sequences == wanted)

        let fadersInBook = ControlInputBank.maximumFaders <= ControlPickupBook.maximumBindings
        let fadersInFaderDispatch = ControlInputBank.maximumFaders <= ControlLocalDispatch.maximumBindings
        let fadersInTriggerDispatch = ControlInputBank.maximumFaders <= ControlLocalTriggerDispatch.maximumBindings
        let fadersInDetector = ControlInputBank.maximumFaders <= ControlTriggerDetector.maximumBindings
        let triggersInBook = ControlInputBank.maximumTriggers <= ControlPickupBook.maximumBindings
        let triggersInFaderDispatch = ControlInputBank.maximumTriggers <= ControlLocalDispatch.maximumBindings
        let triggersInTriggerDispatch = ControlInputBank.maximumTriggers
            <= ControlLocalTriggerDispatch.maximumBindings
        let triggersInDetector = ControlInputBank.maximumTriggers <= ControlTriggerDetector.maximumBindings
        #expect(fadersInBook)
        #expect(fadersInFaderDispatch)
        #expect(fadersInTriggerDispatch)
        #expect(fadersInDetector)
        #expect(triggersInBook)
        #expect(triggersInFaderDispatch)
        #expect(triggersInTriggerDispatch)
        #expect(triggersInDetector)
    }

    @Test
    func controlInputBankSequencesResumeAndEqualBanksStayEqual() throws {
        var resumed = try Fx.bank(after: 10)
        let first = try Fx.hear(&resumed, 80)
        let command = try #require(first.triggers.commands.first)
        #expect(command.sequence == 11)
        #expect(resumed.detector.lastSequence == 11)

        var left = try Fx.bank()
        var right = try Fx.bank()
        let leftResult = try Fx.hear(&left, 70)
        let rightResult = try Fx.hear(&right, 70)
        #expect(leftResult == rightResult)
        #expect(left == right)

        let reversed = try ControlInputBank(
            links: Fx.links().reversed(),
            faders: [Fx.fader("bnd.c", source: Fx.slider7), Fx.fader("bnd.b", pickup: .catch), Fx.fader("bnd.a")],
            triggers: [Fx.trigger("bnd.t")]
        )
        let forward = try Fx.bank()
        #expect(reversed == forward)

        let toggle = try Fx.trigger("bnd.g", source: Fx.pad82, mode: .toggle)
        let twoTriggers = try [Fx.trigger("bnd.t"), toggle]
        let givenOrder = try ControlInputBank(links: Fx.links(), faders: [], triggers: twoTriggers)
        let reverseOrder = try ControlInputBank(links: Fx.links(), faders: [], triggers: twoTriggers.reversed())
        #expect(givenOrder == reverseOrder)
    }
}
