//
//  SetupFlowTests.swift
//  FluxKlangTests
//
//  The startup interface setup flow (#100 SUP1): the builders every SetupFlowTests+*.swift file shares, the bounds of
//  the facts, the field-by-field comparison `matches` and the shape of the apply intent. The flow is a pure value
//  reducer: the reducer reads no device, permission, clock or model.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct SetupFlowTests {
    /// What one `reduce` produced: the next state or a refusal.
    enum Outcome: Equatable {
        case moved(SetupFlowState)
        case refused(SetupFlowRefusal)
    }

    static let rigA = SetupFlowRigID(validated: "rig.a")
    static let rigB = SetupFlowRigID(validated: "rig.b")
    static let rigC = SetupFlowRigID(validated: "rig.c")

    static func facts(
        access: SetupFlowAccess = .granted,
        present: Int = 2,
        lost: Int = 0,
        rigs: [SetupFlowRigID] = [],
        roles: Int = 0
    ) throws(SetupFlowRefusal) -> SetupFlowFacts {
        try SetupFlowFacts.make(
            access: access, presentDevices: present, lostMuted: lost, offeredRigs: rigs, undecidedRoles: roles
        )
    }

    /// The refusal `make` gives for these facts, or nil when they build.
    static func makeRefusal(
        access: SetupFlowAccess = .granted,
        present: Int = 2,
        lost: Int = 0,
        rigs: [SetupFlowRigID] = [],
        roles: Int = 0
    ) -> SetupFlowRefusal? {
        do throws(SetupFlowRefusal) {
            _ = try facts(access: access, present: present, lost: lost, rigs: rigs, roles: roles)
            return nil
        } catch {
            return error
        }
    }

    /// `count` distinct valid rig ids.
    static func manyRigs(_ count: Int) -> [SetupFlowRigID] {
        (0..<count).compactMap { SetupFlowRigID(rawValue: "rig.\($0)") }
    }

    static func attempt(_ state: SetupFlowState, _ event: SetupFlowEvent, _ facts: SetupFlowFacts) -> Outcome {
        do throws(SetupFlowRefusal) {
            return .moved(try SetupFlowReducer.reduce(state, event, facts: facts))
        } catch {
            return .refused(error)
        }
    }

    static func refusal(
        _ state: SetupFlowState,
        _ event: SetupFlowEvent,
        _ facts: SetupFlowFacts
    ) -> SetupFlowRefusal? {
        switch attempt(state, event, facts) {
        case .moved:
            return nil
        case .refused(let refusal):
            return refusal
        }
    }

    /// Applies the events one after the other; the first refusal is thrown.
    static func run(
        _ events: [SetupFlowEvent],
        from start: SetupFlowState,
        facts: SetupFlowFacts
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        var state = start
        for event in events {
            let next = try SetupFlowReducer.reduce(state, event, facts: facts)
            state = next
        }
        return state
    }

    /// The events that walk a flow from `begin()` to `step`, choosing `pick` first when there is one. They are valid
    /// under any facts that pass the gates up to that step.
    static func route(to step: SetupFlowStep, pick: SetupFlowRigID?) -> [SetupFlowEvent] {
        var events: [SetupFlowEvent] = []
        if let rig = pick { events.append(.chooseRig(rig)) }
        switch step {
        case .identify:
            break
        case .map:
            events += [.next]
        case .review:
            events += [.next, .next]
        case .decide:
            events += [.next, .next, .acknowledge(.home), .acknowledge(.runtimeMap), .next]
        }
        return events
    }

    /// A running flow at `step`, reached under `facts` (good facts unless given).
    static func running(
        at step: SetupFlowStep,
        facts: SetupFlowFacts,
        pick: SetupFlowRigID? = nil
    ) throws(SetupFlowRefusal) -> SetupFlowState {
        try run(route(to: step, pick: pick), from: SetupFlowState.begin(), facts: facts)
    }

    /// A suspended flow at `step`, reached under good facts.
    static func suspended(at step: SetupFlowStep) throws(SetupFlowRefusal) -> SetupFlowState {
        let good = try facts()
        let state = try running(at: step, facts: good)
        return try SetupFlowReducer.reduce(state, .cancel, facts: good)
    }

    static let steps: [SetupFlowStep] = [.identify, .map, .review, .decide]

    // MARK: - Facts bounds

    @Test
    func setupFlowPresentDevicesAreBuiltAtZeroOneAndMaxAndRefusedOutsideTheRange() {
        for value in [0, 1, 1_024] {
            let refusal = Self.makeRefusal(present: value)
            #expect(refusal == nil)
        }
        for value in [-1, 1_025, Int.min, Int.max] {
            let refusal = Self.makeRefusal(present: value)
            let expected: SetupFlowRefusal? = .factOutOfRange(.presentDevices, value)
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowLostMutedDevicesAreBuiltAtZeroOneAndMaxAndRefusedOutsideTheRange() {
        for value in [0, 1, 1_024] {
            let refusal = Self.makeRefusal(lost: value)
            #expect(refusal == nil)
        }
        for value in [-1, 1_025, Int.min, Int.max] {
            let refusal = Self.makeRefusal(lost: value)
            let expected: SetupFlowRefusal? = .factOutOfRange(.lostMuted, value)
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowUndecidedRolesAreBuiltAtZeroOneAndMaxAndRefusedOutsideTheRange() {
        for value in [0, 1, 4_096] {
            let refusal = Self.makeRefusal(roles: value)
            #expect(refusal == nil)
        }
        for value in [-1, 4_097, Int.min, Int.max] {
            let refusal = Self.makeRefusal(roles: value)
            let expected: SetupFlowRefusal? = .factOutOfRange(.undecidedRoles, value)
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowOfferedRigsAreBuiltAtZeroOneAndSixteenAndSeventeenIsRefusedWithItsCount() {
        for count in [0, 1, 16] {
            let refusal = Self.makeRefusal(rigs: Self.manyRigs(count))
            #expect(refusal == nil)
        }
        for count in [17, 1_000] {
            let refusal = Self.makeRefusal(rigs: Self.manyRigs(count))
            let expected: SetupFlowRefusal? = .tooManyRigs(count)
            #expect(refusal == expected)
        }
    }

    @Test
    func setupFlowTheDuplicateRigIsTheFirstOfferedRigThatEqualsAnEarlierOne() {
        let repeatedPair = Self.makeRefusal(rigs: [Self.rigA, Self.rigB, Self.rigB, Self.rigA])
        let expectedPair: SetupFlowRefusal? = .duplicateRig(Self.rigB)
        #expect(repeatedPair == expectedPair)
        let adjacent = Self.makeRefusal(rigs: [Self.rigA, Self.rigA])
        let expectedAdjacent: SetupFlowRefusal? = .duplicateRig(Self.rigA)
        #expect(adjacent == expectedAdjacent)
        let distinct = Self.makeRefusal(rigs: [Self.rigC, Self.rigA, Self.rigB])
        #expect(distinct == nil)
    }

    @Test
    func setupFlowMakeKeepsTheCallersRigOrderAndEveryGivenFieldValue() throws {
        let built = try Self.facts(
            access: .notDetermined, present: 3, lost: 5, rigs: [Self.rigC, Self.rigA, Self.rigB], roles: 7
        )
        let expectedAccess: SetupFlowAccess = .notDetermined
        let expectedRigs: [SetupFlowRigID] = [Self.rigC, Self.rigA, Self.rigB]
        #expect(built.access == expectedAccess)
        #expect(built.presentDevices == 3)
        #expect(built.lostMuted == 5)
        #expect(built.offeredRigs == expectedRigs)
        #expect(built.undecidedRoles == 7)
    }

    @Test
    func setupFlowPresentPlusLostMutedDevicesHaveNoCapOfTheirOwn() {
        let refusal = Self.makeRefusal(present: 1_024, lost: 1_024)
        #expect(refusal == nil)
    }

    // MARK: - Facts comparison

    @Test
    func setupFlowMatchesIsTrueForSeparatelyBuiltFactsWithTheSameFiveFields() throws {
        let first = try Self.facts(access: .denied, present: 3, lost: 4, rigs: [Self.rigA, Self.rigB], roles: 5)
        let second = try Self.facts(access: .denied, present: 3, lost: 4, rigs: [Self.rigA, Self.rigB], roles: 5)
        let matching = first.matches(second)
        #expect(matching)
    }

    @Test
    func setupFlowMatchesIsFalseWhenOnlyTheAccessDiffers() throws {
        let first = try Self.facts(access: .granted)
        let second = try Self.facts(access: .denied)
        let matching = first.matches(second)
        #expect(!matching)
    }

    @Test
    func setupFlowMatchesIsFalseWhenOnlyThePresentDevicesDiffer() throws {
        let first = try Self.facts(present: 2)
        let second = try Self.facts(present: 3)
        let matching = first.matches(second)
        #expect(!matching)
    }

    @Test
    func setupFlowMatchesIsFalseWhenOnlyTheLostMutedDevicesDiffer() throws {
        let first = try Self.facts(lost: 0)
        let second = try Self.facts(lost: 1)
        let matching = first.matches(second)
        #expect(!matching)
    }

    @Test
    func setupFlowMatchesIsFalseWhenOnlyTheOrderOfTheOfferedRigsDiffers() throws {
        let first = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let second = try Self.facts(rigs: [Self.rigB, Self.rigA])
        let matching = first.matches(second)
        #expect(!matching)
    }

    @Test
    func setupFlowMatchesIsFalseWhenOnlyTheUndecidedRolesDiffer() throws {
        let first = try Self.facts(roles: 0)
        let second = try Self.facts(roles: 1)
        let matching = first.matches(second)
        #expect(!matching)
    }

    // MARK: - Apply intent

    @Test
    func setupFlowTheApplyIntentHasExactlyTheRigAndBasisMembers() throws {
        let good = try Self.facts()
        let decided = try Self.running(at: .decide, facts: good)
        let ended = try SetupFlowReducer.reduce(decided, .requestApply, facts: good)
        guard case .ended(.applyRequested(let intent)) = ended.phase else {
            Issue.record("the phase after apply was not an apply request")
            return
        }
        let labels = Mirror(reflecting: intent).children.compactMap(\.label)
        let expected = ["rig", "basis"]
        #expect(labels == expected)
    }
}
