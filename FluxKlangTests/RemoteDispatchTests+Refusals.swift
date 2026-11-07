import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteDispatchTests {
    private static let widthBinding = BindingID(validated: "bnd.e-width")
    private static let rangeBinding = BindingID(validated: "bnd.e-range")
    private static let targetBinding = BindingID(validated: "bnd.e-target")
    private static let valueBinding = BindingID(validated: "bnd.e-value")
    private static let stateBinding = BindingID(validated: "bnd.e-state")
    private static let unitBinding = BindingID(validated: "bnd.e-unit")
    private static let classBinding = BindingID(validated: "bnd.e-class")

    /// The standard call with `semantic` in place of its message and the update of a valid control source.
    private static func rawCall(_ semantic: MIDI1Semantic) throws -> Call {
        var raw = try movedCall()
        raw.input = RemoteMIDIInput(semantic: semantic, update: raw.input.update, origin: raw.input.origin)
        return raw
    }

    /// The standard call (a bindable control change) carrying `update`.
    private static func updateCall(
        _ update: MIDI1StateUpdate, dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws -> Call {
        var changed = try movedCall()
        changed.input = RemoteMIDIInput(
            semantic: changed.input.semantic, update: update, origin: changed.input.origin, dialect: dialect
        )
        return changed
    }

    /// The standard call plus one more matched binding in `state`: exactly that binding is refused, its entry is
    /// kept, and the others still propose and hold.
    private static func expectBindingRefused(
        _ extra: ControlBinding, _ refusal: RemoteDispatchRefusal, state: PickupState = .waiting(hardware: 0.4),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        var base = try call()
        base.bindings.append(extra)
        base.pickup[extra.id] = state
        let result = base.run()
        #expect(result.refusals == [refusal], sourceLocation: sourceLocation)
        #expect(proposed(result) == [set(aJump, levelA, 1)], sourceLocation: sourceLocation)
        #expect(result.held == [bCatch], sourceLocation: sourceLocation)
        var table = standardResultPickup
        table[extra.id] = state
        #expect(result.pickup == table, sourceLocation: sourceLocation)
    }

    @Test func aStandaloneRoleProposesNothing() throws {
        var call = try Self.movedCall()
        call.role = try Self.role(.standalone)
        Self.expectRefused(call, .notRemoteController(.standalone))
    }

    @Test func aLostHostProposesNothingWhateverTheGrant() throws {
        for grant in [PeerRole.remoteController, .observer] {
            var call = try Self.movedCall()
            call.role = try Self.role(.hostLost, grant: grant)
            Self.expectRefused(call, .notRemoteController(.hostLost))
        }
    }

    @Test func anObserverGrantProposesNothing() throws {
        var call = try Self.movedCall()
        call.role = try Self.role(.remoteController, grant: .observer)
        Self.expectRefused(call, .observerHasNoCommands)
    }

    @Test func theRoleRefusalFollowsTheGuardForEveryRoleShape() throws {
        let shapes: [(role: RemoteRole, refusal: RemoteDispatchRefusal?)] = try [
            (Self.role(.standalone), .notRemoteController(.standalone)),
            (Self.role(.remoteController), nil),
            (Self.role(.remoteController, grant: .observer), .observerHasNoCommands),
            (Self.role(.hostLost), .notRemoteController(.hostLost)),
            (Self.role(.hostLost, grant: .observer), .notRemoteController(.hostLost))
        ]
        for shape in shapes {
            let decision = RemoteRoleGuard.decide(role: shape.role, capability: .peerUICommand)
            #expect((decision == .allowed) == (shape.refusal == nil))
            var call = try Self.movedCall()
            call.role = shape.role
            if let refusal = shape.refusal {
                Self.expectRefused(call, refusal)
            } else {
                call.pickup = Self.fresh(call.bindings)
                #expect(Self.proposed(call.run()) == [Self.set(Self.aJump, Self.levelA, 1)])
            }
        }
    }

    @Test func rawNoteMessagesAreRefusedEvenWithAValidControlUpdate() throws {
        let notes: [MIDI1Semantic] = [
            .noteOn(channel: 1, note: 60, velocity: 100), .noteOff(channel: 1, note: 60, velocity: 64),
            .polyphonicPressure(channel: 1, note: 60, pressure: 30)
        ]
        for semantic in notes {
            Self.expectRefused(try Self.rawCall(semantic), .rawInput(.refusedRawNote))
        }
    }

    @Test func rawClockAndTransportBytesAreRefusedEvenWithAValidControlUpdate() throws {
        for status: UInt8 in [0xF8, 0xFA, 0xFB, 0xFC] {
            Self.expectRefused(try Self.rawCall(.realTime(status: status)), .rawInput(.refusedRawClock))
        }
    }

    @Test func otherRawSystemMessagesAreRefusedEvenWithAValidControlUpdate() throws {
        let others: [MIDI1Semantic] = [
            .realTime(status: 0xFE), .systemCommon(status: 0xF2, data1: 1, data2: 2), .sysEx(payload: [1, 2])
        ]
        for semantic in others {
            Self.expectRefused(try Self.rawCall(semantic), .rawInput(.refusedRawOther))
        }
    }

    @Test func aProgramChangeIsBindableInputButNamesNoControlSource() throws {
        var call = try Self.movedCall()
        call.input = try Self.message(.programChange(channel: 1, program: 3))
        Self.expectRefused(call, .intake(.notControlInput))
    }

    @Test func aSustainPedalIsBindableInputButNamesNoControlSource() throws {
        var call = try Self.movedCall()
        call.input = try Self.message(.controlChange(channel: 1, controller: 64, value: 127))
        Self.expectRefused(call, .intake(.notControlInput))
    }

    @Test func aMissingMirrorProposesNothing() throws {
        var call = try Self.movedCall()
        call.mirror = nil
        Self.expectRefused(call, .mirrorUnavailable)
    }

    @Test func aMirrorOfAnotherHostProposesNothing() throws {
        var call = try Self.movedCall()
        call.mirror = try Self.mirror(host: Self.hostB)
        Self.expectRefused(call, .staleSession)
    }

    @Test func aMirrorOfTheSameHostFromAnOlderEpochStillProposesBecauseTheRoleHasNoEpoch() throws {
        var call = try Self.call()
        call.mirror = try Self.mirror(hostGeneration: 3)
        let result = call.run()
        let olderSession = try Self.session(hostGeneration: 3)
        #expect(Self.proposed(result) == [Self.set(Self.aJump, Self.levelA, 1)])
        #expect(result.proposals.first?.session == olderSession)
    }

    @Test func anUpdateWithoutAChannelNamesNoControlSource() throws {
        let update = MIDI1StateUpdate(channel: nil, effect: .controller(70, value: 4))
        Self.expectRefused(try Self.updateCall(update), .intake(.noChannel))
    }

    @Test func anUpdateOnAChannelOutsideOneToSixteenNamesNoControlSource() throws {
        for channel in [UInt8(17), 0] {
            let update = MIDI1StateUpdate(channel: channel, effect: .controller(70, value: 4))
            Self.expectRefused(try Self.updateCall(update), .intake(.invalidChannel(Int(channel))))
        }
    }

    @Test func aControllerNumberThatCannotBeASourceIsRefusedWithThatNumber() throws {
        let update = MIDI1StateUpdate(channel: 1, effect: .controller(20, value: 4))
        Self.expectRefused(try Self.updateCall(update), .intake(.invalidNumber(20)))
    }

    @Test func aRawValueAboveItsWidthIsRefusedWithTheValueAndTheMaximum() throws {
        let update = MIDI1StateUpdate(channel: 1, effect: .controller(70, value: 200))
        Self.expectRefused(try Self.updateCall(update), .intake(.rawOutOfRange(raw: 200, maximum: 127)))
    }

    @Test func aLowPartUnderTheMsbOnlyDialectIsRefusedWithTheLowBits() throws {
        let update = MIDI1StateUpdate(channel: 1, effect: .controller14(5, value: 257))
        let call = try Self.updateCall(update, dialect: .msbOnlySevenBit)
        Self.expectRefused(call, .intake(.lsbPresent(raw: 1)))
    }

    @Test func aMatchedBindingWithoutAPickupEntryIsRefusedAloneAndStaysWithoutOne() throws {
        var call = try Self.call()
        call.pickup[Self.aJump] = nil
        let result = call.run()
        #expect(result.refusals == [.pickupStateMissing(Self.aJump)])
        #expect(result.proposals.isEmpty)
        #expect(result.held == [Self.bCatch])
        var table = Self.standardResultPickup
        table[Self.aJump] = nil
        #expect(result.pickup == table)
    }

    @Test func aProfileWiderThanTheMessageIsRefusedForThatBindingAlone() throws {
        let extra = try Self.binding(Self.widthBinding, target: Self.levelA, profile: .absolute(resolution: 1024))
        let refusal = RemoteDispatchRefusal.bindingIntake(
            Self.widthBinding, .widthMismatch(messageBits: 7, profileBits: 14)
        )
        try Self.expectBindingRefused(extra, refusal)
    }

    @Test func aProfileNarrowerThanTheMessageValueIsRefusedForThatBindingAlone() throws {
        let extra = try Self.binding(Self.rangeBinding, target: Self.levelA, profile: .absolute(resolution: 3))
        let refusal = RemoteDispatchRefusal.bindingIntake(Self.rangeBinding, .profileRange(raw: 4, upper: 2))
        try Self.expectBindingRefused(extra, refusal)
    }

    @Test func aTargetOutsideTheMirrorCatalogIsRefusedForThatBindingAlone() throws {
        let extra = try Self.binding(Self.targetBinding, target: Self.missing)
        try Self.expectBindingRefused(extra, .binding(Self.targetBinding, .targetMissing(Self.missing)))
    }

    @Test func aTargetWithoutAMirrorValueIsRefusedForThatBindingAlone() throws {
        let extra = try Self.binding(Self.valueBinding, target: Self.noValue)
        try Self.expectBindingRefused(extra, .binding(Self.valueBinding, .valueUnavailable(Self.noValue)))
    }

    @Test func anUnavailablePickupStateIsRefusedForThatBindingAloneAndKept() throws {
        let extra = try Self.binding(Self.stateBinding, target: Self.levelA)
        try Self.expectBindingRefused(extra, .binding(Self.stateBinding, .pickupUnavailable), state: .unavailable)
    }

    @Test func aBindingInAnotherUnitThanTheTargetIsRefusedForThatBindingAlone() throws {
        let extra = try Self.binding(Self.unitBinding, target: Self.percent)
        let refusal = RemoteDispatchRefusal.binding(
            Self.unitBinding, .unitMismatch(expected: .percent, found: .normalized))
        try Self.expectBindingRefused(extra, refusal)
    }

    @Test func aHazardousTargetIsRefusedForThatBindingAlone() throws {
        let extra = try Self.binding(Self.classBinding, target: Self.locked)
        try Self.expectBindingRefused(extra, .binding(Self.classBinding, .unboundableClass(.hazardous)))
    }
}
