import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteDispatchTests {
    private static let wide = BindingID(validated: "bnd.wide")
    private static let narrow = BindingID(validated: "bnd.narrow")
    private static let orphan = BindingID(validated: "bnd.orphan")
    private static let id1a = BindingID(validated: "bnd.1-a")
    private static let id10b = BindingID(validated: "bnd.10-b")
    private static let id2c = BindingID(validated: "bnd.2-c")
    private static let id3d = BindingID(validated: "bnd.3-d")
    private static let id4e = BindingID(validated: "bnd.4-e")
    private static let id5f = BindingID(validated: "bnd.5-f")
    private static let id6g = BindingID(validated: "bnd.6-g")

    /// Controller 5 as a 14-bit pair (`cc14.5`, 257 positions) and as its 7-bit MSB alone (`cc.5`, quarters).
    private static func dialectBindings() throws -> [ControlBinding] {
        let pairSource = ControlSourceID(validated: "midi.rr2-pad.1.cc14.5")
        let msbSource = ControlSourceID(validated: "midi.rr2-pad.1.cc.5")
        return try [
            binding(wide, target: levelA, source: pairSource, profile: .absolute(resolution: 257)),
            binding(narrow, target: levelB, source: msbSource)
        ]
    }

    /// In ascending id order. Controller 70 at its top gives three proposals (targets D, B, A: not target order),
    /// two held catch bindings (B, A) and two refusals.
    private static func fanOutBindings() throws -> [ControlBinding] {
        try [
            binding(id1a, target: levelD), binding(id10b, target: levelB), binding(id2c, target: levelA),
            binding(id3d, target: levelB, pickup: .catch), binding(id4e, target: levelA, pickup: .catch),
            binding(id5f, target: missing), binding(id6g, target: noValue)
        ]
    }

    @Test func proposeReportsProposalsHeldBindingsAndEveryNewPickupState() throws {
        let call = try Self.call()
        let result = call.run()
        #expect(Self.proposed(result) == [Self.set(Self.aJump, Self.levelA, 1)])
        #expect(result.held == [Self.bCatch])
        #expect(result.refusals.isEmpty)
        #expect(result.pickup == Self.standardResultPickup)
        #expect(call.run() == result)
    }

    @Test func aProposalCarriesItsBindingTargetOperationBasisAndSession() throws {
        let result = try Self.call().run()
        let proposal = try #require(result.proposals.first)
        let basis = try Self.deltaRevisions()
        let session = try Self.session()
        #expect(result.proposals.count == 1)
        #expect(proposal.binding == Self.aJump)
        #expect(proposal.target == Self.levelA)
        #expect(proposal.operation == .set(Self.levelA, Self.normalized(1)))
        #expect(proposal.basis == basis)
        #expect(proposal.session == session)
    }

    @Test func aCatchBindingEngagesAndProposesWhenTheInputCrossesTheHostValue() throws {
        var call = try Self.call()
        call.pickup[Self.bCatch] = .waiting(hardware: 1)
        call.input = try Self.controller(70, 0)
        let result = call.run()
        #expect(Self.proposed(result) == [
            Self.set(Self.aJump, Self.levelA, 0), Self.set(Self.bCatch, Self.levelB, 0),
            Self.set(Self.cFull, Self.levelC, 0)
        ])
        #expect(result.held.isEmpty)
        #expect(result.refusals.isEmpty)
        #expect(result.pickup[Self.bCatch] == .engaged(hardware: 0))
    }

    @Test func aCatchBindingOnTheSameSideOfTheHostValueKeepsHoldingAndRemembersTheInput() throws {
        var call = try Self.call()
        call.pickup[Self.bCatch] = .waiting(hardware: 0)
        call.input = try Self.controller(70, 2)
        let result = call.run()
        #expect(result.held == [Self.bCatch])
        #expect(Self.proposed(result) == [
            Self.set(Self.aJump, Self.levelA, 0.5), Self.set(Self.cFull, Self.levelC, 0.5)
        ])
        #expect(result.pickup[Self.bCatch] == .waiting(hardware: 0.5))
    }

    @Test func aCatchBindingLandingExactlyOnTheHostValueEngagesWithoutAProposal() throws {
        var call = try Self.call()
        call.input = try Self.controller(70, 3)
        let result = call.run()
        #expect(result.held.isEmpty)
        #expect(Self.proposed(result) == [
            Self.set(Self.aJump, Self.levelA, 0.75), Self.set(Self.cFull, Self.levelC, 0.75)
        ])
        #expect(result.pickup[Self.bCatch] == .engaged(hardware: 0.75))
    }

    @Test func aRelativeBindingStepsTheMirrorValueByTheDecodedDetents() throws {
        var call = try Self.call()
        call.input = try Self.controller(71, 1)
        let stepUp = call.run()
        #expect(Self.proposed(stepUp) == [Self.set(Self.dRel, Self.levelD, 0.75)])
        #expect(stepUp.held.isEmpty && stepUp.refusals.isEmpty)
        #expect(stepUp.pickup[Self.dRel] == .engaged(hardware: nil))
        call.input = try Self.controller(71, 127)
        #expect(Self.proposed(call.run()) == [Self.set(Self.dRel, Self.levelD, 0.25)])
        call.input = try Self.controller(71, 0)
        Self.expectIdle(call.run(), pickup: call.pickup)
    }

    @Test func onlyBindingsOfTheInputSourceAreEvaluatedAndTheOthersKeepTheirStates() throws {
        var call = try Self.movedCall()
        call.input = try Self.controller(71, 1)
        let result = call.run()
        #expect(Self.proposed(result) == [Self.set(Self.dRel, Self.levelD, 0.75)])
        #expect(result.held.isEmpty)
        #expect(result.refusals.isEmpty)
        #expect(result.pickup == Self.movedPickup)
    }

    @Test func inputsFromAnotherChannelOrAnotherOriginMatchNoBinding() throws {
        var call = try Self.movedCall()
        call.input = try Self.controller(70, 4, channel: 2)
        Self.expectIdle(call.run(), pickup: Self.movedPickup)
        call.input = try Self.controller(70, 4, origin: "rr2-other")
        Self.expectIdle(call.run(), pickup: Self.movedPickup)
    }

    @Test func theInputDialectDecidesWhichBindingOnControllerFiveMatches() throws {
        let bindings = try Self.dialectBindings()
        var call = try Self.call()
        call.bindings = bindings
        call.pickup = Self.fresh(bindings)
        let pair: [MIDI1Semantic] = [
            .controlChange(channel: 1, controller: 5, value: 2), .controlChange(channel: 1, controller: 37, value: 0)
        ]
        call.input = try Self.message(pair[0], pair[1])
        let paired = call.run()
        #expect(Self.proposed(paired) == [Self.set(Self.wide, Self.levelA, 1)])
        #expect(paired.held.isEmpty && paired.refusals.isEmpty)
        #expect(paired.pickup == [Self.wide: .engaged(hardware: 1), Self.narrow: .engaged(hardware: nil)])
        call.input = try Self.message(pair[0], pair[1], dialect: .msbOnlySevenBit)
        let msbOnly = call.run()
        #expect(Self.proposed(msbOnly) == [Self.set(Self.narrow, Self.levelB, 0.5)])
        #expect(msbOnly.held.isEmpty && msbOnly.refusals.isEmpty)
        #expect(msbOnly.pickup == [Self.wide: .engaged(hardware: nil), Self.narrow: .engaged(hardware: 0.5)])
    }

    @Test func anInputBuiltWithoutADialectReadsFourteenBitPairs() throws {
        let input = try RemoteMIDIInput(
            semantic: .controlChange(channel: 1, controller: 70, value: 4),
            update: MIDI1StateUpdate(channel: 1, effect: .controller(70, value: 4)),
            origin: ControlSourceOrigin("rr2-pad")
        )
        #expect(input.dialect == .pairedFourteenBit)
    }

    @Test func resultsFollowAscendingBindingIdWhateverOrderTheBindingsArrive() throws {
        let ascending = try Self.fanOutBindings()
        var call = try Self.call()
        call.bindings = ascending
        call.pickup = Self.fresh(ascending)
        let expected = call.run()
        #expect(expected.proposals.map(\.binding) == [Self.id1a, Self.id10b, Self.id2c])
        #expect(expected.held == [Self.id3d, Self.id4e])
        #expect(expected.refusals == [
            .binding(Self.id5f, .targetMissing(Self.missing)), .binding(Self.id6g, .valueUnavailable(Self.noValue))
        ])
        call.bindings = Array(ascending.reversed())
        #expect(call.run() == expected)
        call.bindings = Array(ascending[3...] + ascending[..<3])
        #expect(call.run() == expected)
    }

    @Test func theReturnedPickupTableKeepsEveryUnevaluatedEntryAndReplacesEvaluatedOnes() throws {
        var call = try Self.movedCall()
        call.pickup[Self.orphan] = .waiting(hardware: 0.2)
        call.pickup[Self.dRel] = .waiting(hardware: 0.3)
        call.input = try Self.controller(71, 1)
        var expected = call.pickup
        expected[Self.dRel] = .engaged(hardware: nil)
        #expect(call.run().pickup == expected)
    }

    @Test func theReturnedPickupTableFeedsTheNextCall() throws {
        var call = try Self.call()
        let first = call.run()
        #expect(first.held == [Self.bCatch])
        call.pickup = first.pickup
        call.input = try Self.controller(70, 0)
        let second = call.run()
        #expect(Self.proposed(second) == [
            Self.set(Self.aJump, Self.levelA, 0), Self.set(Self.bCatch, Self.levelB, 0),
            Self.set(Self.cFull, Self.levelC, 0)
        ])
        #expect(second.held.isEmpty)
        #expect(second.pickup[Self.bCatch] == .engaged(hardware: 0))
    }

    @Test func zeroBindingsIsALegalCallThatLeavesTheTableAlone() throws {
        var call = try Self.movedCall()
        call.bindings = []
        Self.expectIdle(call.run(), pickup: Self.movedPickup)
    }

    @Test func aPerformanceStateUpdateDrivesTheSameResultAsTheHandBuiltPair() throws {
        let parsed = try Self.message(.controlChange(channel: 1, controller: 70, value: 4))
        var call = try Self.call()
        #expect(parsed.update == call.input.update)
        #expect(parsed.semantic == call.input.semantic)
        let expected = call.run()
        call.input = parsed
        #expect(call.run() == expected)
    }
}
