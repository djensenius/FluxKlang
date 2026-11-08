//
//  SetupFlowTests+Flow.swift
//  FluxKlangTests
//
//  The gates and the step moves of the setup flow: which gates `next` and the apply request check at each step, each
//  gate on both sides of its limit, the two panes and the facts they were acknowledged under, choosing a rig, going
//  back, and two hand-written walks from the first step to an apply request.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SetupFlowTests {
    /// The phase after `event`, or nil when it was refused.
    static func phase(_ state: SetupFlowState, _ event: SetupFlowEvent, _ facts: SetupFlowFacts) -> SetupFlowPhase? {
        switch attempt(state, event, facts) {
        case .moved(let moved):
            return moved.phase
        case .refused:
            return nil
        }
    }

    /// Builds a review step under `base`, acknowledges both panes under `base`, then reports what `next` gives under
    /// `changed` for four acknowledgement mixes: both panes stale, only home fresh, both fresh, only runtime-map fresh.
    static func paneProbe(
        base: SetupFlowFacts,
        changed: SetupFlowFacts,
        pick: SetupFlowRigID?
    ) throws(SetupFlowRefusal) -> [SetupFlowRefusal?] {
        let review = try running(at: .review, facts: base, pick: pick)
        let bothStale = try run([.acknowledge(.home), .acknowledge(.runtimeMap)], from: review, facts: base)
        let homeFresh = try run([.acknowledge(.home)], from: bothStale, facts: changed)
        let bothFresh = try run([.acknowledge(.runtimeMap)], from: homeFresh, facts: changed)
        let mapFresh = try run([.acknowledge(.runtimeMap)], from: bothStale, facts: changed)
        return [
            refusal(bothStale, .next, changed), refusal(homeFresh, .next, changed),
            refusal(bothFresh, .next, changed), refusal(mapFresh, .next, changed)
        ]
    }

    // MARK: - Which gates each step checks

    @Test
    func setupFlowNextLeavingIdentifyIgnoresTheRolesAndThePanes() throws {
        let good = try Self.facts()
        let withRoles = try Self.facts(roles: 3)
        let state = try Self.running(at: .identify, facts: good)
        let after = Self.phase(state, .next, withRoles)
        let expected: SetupFlowPhase? = .running(.map)
        #expect(after == expected)
    }

    @Test
    func setupFlowNextLeavingMapChecksTheRolesButNotThePanes() throws {
        let good = try Self.facts()
        let withRoles = try Self.facts(roles: 1)
        let state = try Self.running(at: .map, facts: good)
        let refused = Self.refusal(state, .next, withRoles)
        let expectedRefusal: SetupFlowRefusal? = .rolesUndecided(1)
        #expect(refused == expectedRefusal)
        let after = Self.phase(state, .next, good)
        let expectedPhase: SetupFlowPhase? = .running(.review)
        #expect(after == expectedPhase)
    }

    @Test
    func setupFlowNextLeavingReviewChecksTheHomePaneThenTheRuntimeMapPane() throws {
        let good = try Self.facts()
        let state = try Self.running(at: .review, facts: good)
        let neither = Self.refusal(state, .next, good)
        let expectedNeither: SetupFlowRefusal? = .paneNotReviewed(.home)
        #expect(neither == expectedNeither)
        let homeOnly = try Self.run([.acknowledge(.home)], from: state, facts: good)
        let homeOnlyRefusal = Self.refusal(homeOnly, .next, good)
        let expectedHomeOnly: SetupFlowRefusal? = .paneNotReviewed(.runtimeMap)
        #expect(homeOnlyRefusal == expectedHomeOnly)
        let both = try Self.run([.acknowledge(.home), .acknowledge(.runtimeMap)], from: state, facts: good)
        let after = Self.phase(both, .next, good)
        let expectedPhase: SetupFlowPhase? = .running(.decide)
        #expect(after == expectedPhase)
    }

    @Test
    func setupFlowAnApplyRequestAtTheIdentifyMapOrReviewStepIsRefusedAsWrongStep() throws {
        let good = try Self.facts()
        for step in [SetupFlowStep.identify, .map, .review] {
            let state = try Self.running(at: step, facts: good)
            let refusal = Self.refusal(state, .requestApply, good)
            let expected: SetupFlowRefusal? = .wrongStep(expected: .decide)
            #expect(refusal == expected)
        }
    }

    // MARK: - Gate 1: access

    @Test
    func setupFlowOnlyGrantedAccessPassesAndTheOthersAreRefusedWithTheirOwnValue() throws {
        let good = try Self.facts()
        let state = try Self.running(at: .identify, facts: good)
        let denied = try Self.facts(access: .denied)
        let undetermined = try Self.facts(access: .notDetermined)
        let deniedRefusal = Self.refusal(state, .next, denied)
        let expectedDenied: SetupFlowRefusal? = .permissionNotGranted(.denied)
        #expect(deniedRefusal == expectedDenied)
        let undeterminedRefusal = Self.refusal(state, .next, undetermined)
        let expectedUndetermined: SetupFlowRefusal? = .permissionNotGranted(.notDetermined)
        #expect(undeterminedRefusal == expectedUndetermined)
        let granted = Self.phase(state, .next, good)
        let expectedGranted: SetupFlowPhase? = .running(.map)
        #expect(granted == expectedGranted)
    }

    // MARK: - Gate 2: devices

    @Test
    func setupFlowOneOrMorePresentDevicesPassAndNoneIsRefusedEvenWithTheMaximumLost() throws {
        let good = try Self.facts()
        let state = try Self.running(at: .identify, facts: good)
        let onlyLost = try Self.facts(present: 0, lost: 1_024)
        let refusal = Self.refusal(state, .next, onlyLost)
        let expected: SetupFlowRefusal? = .noPresentDevice
        #expect(refusal == expected)
        let noneAtAll = try Self.facts(present: 0)
        let noneRefusal = Self.refusal(state, .next, noneAtAll)
        #expect(noneRefusal == expected)
        let expectedPhase: SetupFlowPhase? = .running(.map)
        for present in [1, 1_024] {
            let enough = try Self.facts(present: present)
            let after = Self.phase(state, .next, enough)
            #expect(after == expectedPhase)
        }
    }

    @Test
    func setupFlowOneLostMutedDeviceOrMaxDoNotBlockWhileOneDeviceIsPresent() throws {
        let good = try Self.facts()
        let state = try Self.running(at: .identify, facts: good)
        let expectedPhase: SetupFlowPhase? = .running(.map)
        for lost in [1, 1_024] {
            let facts = try Self.facts(present: 1, lost: lost)
            let after = Self.phase(state, .next, facts)
            #expect(after == expectedPhase)
        }
    }

    // MARK: - Gate 3: rig

    @Test
    func setupFlowNoOfferedRigAndNoPickPassesAndTheApplyIntentCarriesNoRig() throws {
        let good = try Self.facts()
        let decided = try Self.running(at: .decide, facts: good)
        let ended = try SetupFlowReducer.reduce(decided, .requestApply, facts: good)
        guard case .ended(.applyRequested(let intent)) = ended.phase else {
            Issue.record("the phase after apply was not an apply request")
            return
        }
        #expect(intent.rig == nil)
    }

    @Test
    func setupFlowOfferedRigsWithNoPickAreRefusedEvenWhenOnlyOneIsOffered() throws {
        let good = try Self.facts()
        let state = try Self.running(at: .identify, facts: good)
        for rigs in [[Self.rigA], [Self.rigA, Self.rigB]] {
            let offered = try Self.facts(rigs: rigs)
            let refusal = Self.refusal(state, .next, offered)
            let expected: SetupFlowRefusal? = .rigNotChosen
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowAPickThatIsNoLongerOfferedIsRefusedWhetherOtherRigsOrNoneAreOffered() throws {
        let offeredA = try Self.facts(rigs: [Self.rigA])
        let state = try Self.running(at: .identify, facts: offeredA, pick: Self.rigA)
        let expected: SetupFlowRefusal? = .rigNotOffered(Self.rigA)
        let otherRig = try Self.facts(rigs: [Self.rigB])
        let otherRefusal = Self.refusal(state, .next, otherRig)
        #expect(otherRefusal == expected)
        let noRigs = try Self.facts()
        let emptyRefusal = Self.refusal(state, .next, noRigs)
        #expect(emptyRefusal == expected)
        let stillOffered = Self.phase(state, .next, offeredA)
        let expectedPhase: SetupFlowPhase? = .running(.map)
        #expect(stillOffered == expectedPhase)
    }

    // MARK: - Gate 4: roles

    @Test
    func setupFlowNoUndecidedRolesPassAndOneOrMaxAreRefusedWithTheirCount() throws {
        let good = try Self.facts()
        let state = try Self.running(at: .map, facts: good)
        for roles in [1, 4_096] {
            let facts = try Self.facts(roles: roles)
            let refusal = Self.refusal(state, .next, facts)
            let expected: SetupFlowRefusal? = .rolesUndecided(roles)
            #expect(refusal == expected)
        }
        let after = Self.phase(state, .next, good)
        let expectedPhase: SetupFlowPhase? = .running(.review)
        #expect(after == expectedPhase)
    }

    // MARK: - Gates 5 and 6: panes

    @Test
    func setupFlowAcknowledgingAPaneStoresTheFactsItWasMadeUnderAndNothingForTheOtherPane() throws {
        let good = try Self.facts()
        let other = try Self.facts(present: 5)
        let review = try Self.running(at: .review, facts: good)
        let home = try SetupFlowReducer.reduce(review, .acknowledge(.home), facts: other)
        let homeSeen = try #require(home.homeSeenUnder)
        #expect(homeSeen.presentDevices == 5)
        #expect(home.runtimeMapSeenUnder == nil)
        let both = try SetupFlowReducer.reduce(home, .acknowledge(.runtimeMap), facts: good)
        let mapSeen = try #require(both.runtimeMapSeenUnder)
        #expect(mapSeen.presentDevices == 2)
        let homeKept = try #require(both.homeSeenUnder)
        #expect(homeKept.presentDevices == 5)
    }

    @Test
    func setupFlowAcknowledgingDoesNotMoveTheStepOrTheRig() throws {
        let offered = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let review = try Self.running(at: .review, facts: offered, pick: Self.rigB)
        let after = try SetupFlowReducer.reduce(review, .acknowledge(.home), facts: offered)
        let expectedPhase: SetupFlowPhase = .running(.review)
        #expect(after.phase == expectedPhase)
        #expect(after.pickedRig == Self.rigB)
    }

    @Test
    func setupFlowAChangeOfPresentDevicesLostDevicesOrOfferedRigsReopensBothPanes() throws {
        let expected: [SetupFlowRefusal?] = [
            .paneNotReviewed(.home), .paneNotReviewed(.runtimeMap), nil, .paneNotReviewed(.home)
        ]
        let base = try Self.facts()
        let present = try Self.paneProbe(base: base, changed: Self.facts(present: 3), pick: nil)
        #expect(present == expected)
        let lost = try Self.paneProbe(base: base, changed: Self.facts(lost: 1), pick: nil)
        #expect(lost == expected)
        let offered = try Self.facts(rigs: [Self.rigA])
        let more = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let rigs = try Self.paneProbe(base: offered, changed: more, pick: Self.rigA)
        #expect(rigs == expected)
    }

    @Test
    func setupFlowChoosingARigAgainClearsBothAcknowledgements() throws {
        let offered = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let review = try Self.running(at: .review, facts: offered, pick: Self.rigA)
        let acknowledged = try Self.run(
            [.acknowledge(.home), .acknowledge(.runtimeMap)], from: review, facts: offered
        )
        let rewound = try Self.run([.back, .back], from: acknowledged, facts: offered)
        let rechosen = try SetupFlowReducer.reduce(rewound, .chooseRig(Self.rigA), facts: offered)
        #expect(rechosen.homeSeenUnder == nil)
        #expect(rechosen.runtimeMapSeenUnder == nil)
        let backAtReview = try Self.run([.next, .next], from: rechosen, facts: offered)
        let refusal = Self.refusal(backAtReview, .next, offered)
        let expected: SetupFlowRefusal? = .paneNotReviewed(.home)
        #expect(refusal == expected)
    }

    // MARK: - Choosing a rig, acknowledging, going back

    @Test
    func setupFlowChoosingARigWorksOnlyAtIdentifyAndOtherStepsAreRefusedAsWrongStep() throws {
        let offered = try Self.facts(rigs: [Self.rigA])
        let expected: SetupFlowRefusal? = .wrongStep(expected: .identify)
        for step in [SetupFlowStep.map, .review, .decide] {
            let state = try Self.running(at: step, facts: offered, pick: Self.rigA)
            let refusal = Self.refusal(state, .chooseRig(Self.rigA), offered)
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowChoosingARigThatIsNotOfferedIsRefusedAlsoWhenNothingIsOffered() throws {
        let offeredA = try Self.facts(rigs: [Self.rigA])
        let none = try Self.facts()
        let atIdentify = SetupFlowState.begin()
        let notOffered = Self.refusal(atIdentify, .chooseRig(Self.rigB), offeredA)
        let expected: SetupFlowRefusal? = .rigNotOffered(Self.rigB)
        #expect(notOffered == expected)
        let emptyOffer = Self.refusal(atIdentify, .chooseRig(Self.rigB), none)
        #expect(emptyOffer == expected)
    }

    @Test
    func setupFlowChoosingARigReplacesThePickAndStaysAtIdentify() throws {
        let offered = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let first = try SetupFlowReducer.reduce(SetupFlowState.begin(), .chooseRig(Self.rigA), facts: offered)
        #expect(first.pickedRig == Self.rigA)
        let second = try SetupFlowReducer.reduce(first, .chooseRig(Self.rigB), facts: offered)
        #expect(second.pickedRig == Self.rigB)
        let expectedPhase: SetupFlowPhase = .running(.identify)
        #expect(second.phase == expectedPhase)
    }

    @Test
    func setupFlowAcknowledgingWorksOnlyAtReviewAndOtherStepsAreRefusedAsWrongStep() throws {
        let good = try Self.facts()
        let expected: SetupFlowRefusal? = .wrongStep(expected: .review)
        for step in [SetupFlowStep.identify, .map, .decide] {
            let state = try Self.running(at: step, facts: good)
            let refusal = Self.refusal(state, .acknowledge(.home), good)
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowBackMovesOneStepUnderFactsThatFailThreeGatesAndIsRefusedAtIdentify() throws {
        let good = try Self.facts()
        let denied = try Self.facts(access: .denied, present: 0, roles: 9)
        let expectedBack: [SetupFlowStep] = [.review, .map, .identify]
        var current = try Self.running(at: .decide, facts: good)
        for step in expectedBack {
            current = try SetupFlowReducer.reduce(current, .back, facts: denied)
            let expectedPhase: SetupFlowPhase = .running(step)
            #expect(current.phase == expectedPhase)
        }
        let refusal = Self.refusal(current, .back, denied)
        let expected: SetupFlowRefusal? = .noPreviousStep
        #expect(refusal == expected)
    }

    @Test
    func setupFlowBackKeepsThePickAndBothAcknowledgements() throws {
        let offered = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let decided = try Self.running(at: .decide, facts: offered, pick: Self.rigB)
        let back = try SetupFlowReducer.reduce(decided, .back, facts: offered)
        #expect(back.pickedRig == decided.pickedRig)
        #expect(back.homeSeenUnder == decided.homeSeenUnder)
        #expect(back.runtimeMapSeenUnder == decided.runtimeMapSeenUnder)
        #expect(back.pickedRig == Self.rigB)
        #expect(back.homeSeenUnder != nil)
        #expect(back.runtimeMapSeenUnder != nil)
    }

    // MARK: - Walks

    @Test
    func setupFlowWalkAWithNoRigsGoesFromIdentifyToAnApplyRequestWithNoRig() throws {
        let good = try Self.facts(access: .granted, present: 2, lost: 0, rigs: [], roles: 0)
        let events: [SetupFlowEvent] = [
            .next, .next, .acknowledge(.home), .acknowledge(.runtimeMap), .next
        ]
        let phases: [SetupFlowPhase] = [
            .running(.map), .running(.review), .running(.review), .running(.review), .running(.decide)
        ]
        var state = SetupFlowState.begin()
        for (event, expected) in zip(events, phases) {
            state = try SetupFlowReducer.reduce(state, event, facts: good)
            #expect(state.phase == expected)
        }
        let ended = try SetupFlowReducer.reduce(state, .requestApply, facts: good)
        guard case .ended(.applyRequested(let intent)) = ended.phase else {
            Issue.record("the phase after apply was not an apply request")
            return
        }
        #expect(intent.rig == nil)
        let expectedAccess: SetupFlowAccess = .granted
        #expect(intent.basis.access == expectedAccess)
        #expect(intent.basis.presentDevices == 2)
        #expect(intent.basis.lostMuted == 0)
        #expect(intent.basis.offeredRigs.isEmpty)
        #expect(intent.basis.undecidedRoles == 0)
    }

    @Test
    func setupFlowWalkBWithTwoRigsAndALostDeviceEndsWithTheChosenRigAndTheBasisFacts() throws {
        let offered = try Self.facts(access: .granted, present: 1, lost: 1, rigs: [Self.rigA, Self.rigB], roles: 0)
        let events: [SetupFlowEvent] = [
            .chooseRig(Self.rigB), .next, .next, .acknowledge(.home), .acknowledge(.runtimeMap), .next, .requestApply
        ]
        let ended = try Self.run(events, from: SetupFlowState.begin(), facts: offered)
        guard case .ended(.applyRequested(let intent)) = ended.phase else {
            Issue.record("the phase after apply was not an apply request")
            return
        }
        #expect(intent.rig == Self.rigB)
        let expectedRigs: [SetupFlowRigID] = [Self.rigA, Self.rigB]
        #expect(intent.basis.offeredRigs == expectedRigs)
        #expect(intent.basis.presentDevices == 1)
        #expect(intent.basis.lostMuted == 1)
        #expect(ended.pickedRig == Self.rigB)
    }
}
