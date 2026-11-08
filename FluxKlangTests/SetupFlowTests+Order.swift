//
//  SetupFlowTests+Order.swift
//  FluxKlangTests
//
//  Which refusal wins when an input holds two defects: the order in which `make` checks the facts, and the order in
//  which `reduce` checks the phase, the step fit, the choose-rig payload and the six gates. Every fixture holds both
//  defects of its pair, so a swapped order gives a different refusal. For the gate pairs, a decide state is built under
//  good facts and then given bad facts at the apply request.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SetupFlowTests {
    // MARK: - make

    @Test
    func setupFlowMakeReportsTheRigCountBeforeAnOutOfRangePresentCount() {
        let refusal = Self.makeRefusal(present: 1_025, rigs: Self.manyRigs(17))
        let expected: SetupFlowRefusal? = .tooManyRigs(17)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowMakeReportsThePresentCountBeforeAnOutOfRangeLostCount() {
        let refusal = Self.makeRefusal(present: -1, lost: -1)
        let expected: SetupFlowRefusal? = .factOutOfRange(.presentDevices, -1)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowMakeReportsTheLostCountBeforeAnOutOfRangeRoleCount() {
        let refusal = Self.makeRefusal(lost: 1_025, roles: 4_097)
        let expected: SetupFlowRefusal? = .factOutOfRange(.lostMuted, 1_025)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowMakeReportsTheRoleCountBeforeADuplicateRig() {
        let refusal = Self.makeRefusal(rigs: [Self.rigA, Self.rigA], roles: -1)
        let expected: SetupFlowRefusal? = .factOutOfRange(.undecidedRoles, -1)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowMakeCountsTheRigsBeforeLookingForADuplicate() {
        let seventeenCopies = Array(repeating: Self.rigA, count: 17)
        let refusal = Self.makeRefusal(rigs: seventeenCopies)
        let expected: SetupFlowRefusal? = .tooManyRigs(17)
        #expect(refusal == expected)
    }

    // MARK: - phase and step fit

    @Test
    func setupFlowASuspendedFlowRefusesAnApplyRequestAsSuspendedEvenAtTheWrongStep() throws {
        let state = try Self.suspended(at: .identify)
        let good = try Self.facts()
        let refusal = Self.refusal(state, .requestApply, good)
        let expected: SetupFlowRefusal? = .suspended
        #expect(refusal == expected)
    }

    @Test
    func setupFlowAChooseRigAtTheWrongStepIsRefusedAsWrongStepEvenWhenTheRigIsNotOffered() throws {
        let good = try Self.facts()
        let state = try Self.running(at: .map, facts: good)
        let refusal = Self.refusal(state, .chooseRig(Self.rigC), good)
        let expected: SetupFlowRefusal? = .wrongStep(expected: .identify)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowAnApplyRequestAtTheWrongStepIsRefusedAsWrongStepEvenWhenAccessIsDenied() throws {
        let good = try Self.facts()
        let denied = try Self.facts(access: .denied)
        let state = try Self.running(at: .identify, facts: good)
        let refusal = Self.refusal(state, .requestApply, denied)
        let expected: SetupFlowRefusal? = .wrongStep(expected: .decide)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowNextAtTheDecideStepIsRefusedAsNoNextStepEvenWhenAccessIsDenied() throws {
        let good = try Self.facts()
        let denied = try Self.facts(access: .denied)
        let state = try Self.running(at: .decide, facts: good)
        let refusal = Self.refusal(state, .next, denied)
        let expected: SetupFlowRefusal? = .noNextStep
        #expect(refusal == expected)
    }

    // MARK: - gates

    @Test
    func setupFlowTheAccessGateComesBeforeTheDeviceGate() throws {
        let good = try Self.facts()
        let bad = try Self.facts(access: .denied, present: 0)
        let state = try Self.running(at: .decide, facts: good)
        let refusal = Self.refusal(state, .requestApply, bad)
        let expected: SetupFlowRefusal? = .permissionNotGranted(.denied)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowTheDeviceGateComesBeforeTheRigGate() throws {
        let good = try Self.facts()
        let noPick = try Self.running(at: .decide, facts: good)
        let offeredNoPick = try Self.facts(present: 0, rigs: [Self.rigA, Self.rigB])
        let noPickRefusal = Self.refusal(noPick, .requestApply, offeredNoPick)
        let expectedNoPick: SetupFlowRefusal? = .noPresentDevice
        #expect(noPickRefusal == expectedNoPick)
        let offeredBoth = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let picked = try Self.running(at: .decide, facts: offeredBoth, pick: Self.rigA)
        let notOffered = try Self.facts(present: 0, rigs: [Self.rigB, Self.rigC])
        let pickedRefusal = Self.refusal(picked, .requestApply, notOffered)
        let expectedPicked: SetupFlowRefusal? = .noPresentDevice
        #expect(pickedRefusal == expectedPicked)
    }

    @Test
    func setupFlowTheRigGateComesBeforeTheRoleGate() throws {
        let good = try Self.facts()
        let noPick = try Self.running(at: .decide, facts: good)
        let offeredNoPick = try Self.facts(rigs: [Self.rigA, Self.rigB], roles: 1)
        let noPickRefusal = Self.refusal(noPick, .requestApply, offeredNoPick)
        let expectedNoPick: SetupFlowRefusal? = .rigNotChosen
        #expect(noPickRefusal == expectedNoPick)
        let offeredBoth = try Self.facts(rigs: [Self.rigA, Self.rigB])
        let picked = try Self.running(at: .decide, facts: offeredBoth, pick: Self.rigA)
        let notOffered = try Self.facts(rigs: [Self.rigB], roles: 1)
        let pickedRefusal = Self.refusal(picked, .requestApply, notOffered)
        let expectedPicked: SetupFlowRefusal? = .rigNotOffered(Self.rigA)
        #expect(pickedRefusal == expectedPicked)
    }

    @Test
    func setupFlowTheRoleGateComesBeforeTheHomePaneGate() throws {
        let good = try Self.facts()
        let bad = try Self.facts(roles: 1)
        let state = try Self.running(at: .decide, facts: good)
        let refusal = Self.refusal(state, .requestApply, bad)
        let expected: SetupFlowRefusal? = .rolesUndecided(1)
        #expect(refusal == expected)
    }

    @Test
    func setupFlowTheHomePaneGateComesBeforeTheRuntimeMapPaneGate() throws {
        let good = try Self.facts()
        let changed = try Self.facts(present: 3)
        let state = try Self.running(at: .decide, facts: good)
        let refusal = Self.refusal(state, .requestApply, changed)
        let expected: SetupFlowRefusal? = .paneNotReviewed(.home)
        #expect(refusal == expected)
    }
}
