//
//  SetupFlowScreenTests.swift
//  FluxKlangTests
//
//  The setup flow screen model (#100 RLS1): what each action would do now, the one blocker of the forward action, the
//  manual offer, the fixed sentences, and a scan of the two production files. States are reached only by driving the
//  real reducer from `begin()`.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct SetupFlowScreenTests {
    private struct Row: Equatable {
        let event: SetupFlowEvent
        let verdict: SetupFlowScreenVerdict
    }

    /// The expected verdict of each event kind; `chooseRig` is one verdict for every offered rig.
    private struct Kinds {
        var next = SetupFlowScreenVerdict.enabled
        var back = SetupFlowScreenVerdict.enabled
        var choose = SetupFlowScreenVerdict.enabled
        var home = SetupFlowScreenVerdict.enabled
        var runtimeMap = SetupFlowScreenVerdict.enabled
        var apply = SetupFlowScreenVerdict.enabled
        var stay = SetupFlowScreenVerdict.enabled
        var cancel = SetupFlowScreenVerdict.enabled
        var reopen = SetupFlowScreenVerdict.refused(.notSuspended)
    }

    static let rigA = SetupFlowRigID(validated: "rig.a")
    static let rigB = SetupFlowRigID(validated: "rig.b")
    private static let rigC = SetupFlowRigID(validated: "rig.c")

    static func facts(
        access: SetupFlowAccess = .granted,
        present: Int = 2,
        lost: Int = 0,
        rigs: [SetupFlowRigID] = [],
        roles: Int = 0
    ) throws -> SetupFlowFacts {
        try SetupFlowFacts.make(
            access: access, presentDevices: present, lostMuted: lost, offeredRigs: rigs, undecidedRoles: roles
        )
    }

    static func drive(_ events: [SetupFlowEvent], _ facts: SetupFlowFacts) throws -> SetupFlowState {
        var state = SetupFlowState.begin()
        for event in events {
            state = try SetupFlowReducer.reduce(state, event, facts: facts)
        }
        return state
    }

    /// The events that bring a flow to `step` under facts without roles to decide; `rig` is picked first when given.
    static func path(to step: SetupFlowStep, pick rig: SetupFlowRigID? = nil) -> [SetupFlowEvent] {
        let pick: [SetupFlowEvent] = rig.map { [.chooseRig($0)] } ?? []
        switch step {
        case .identify:
            return pick
        case .map:
            return pick + [.next]
        case .review:
            return pick + [.next, .next]
        case .decide:
            return pick + [.next, .next, .acknowledge(.home), .acknowledge(.runtimeMap), .next]
        }
    }

    static func screen(
        after events: [SetupFlowEvent],
        built: SetupFlowFacts,
        shown: SetupFlowFacts? = nil
    ) throws -> SetupFlowScreen {
        SetupFlowScreen.make(try drive(events, built), facts: shown ?? built)
    }

    private static func rows(_ screen: SetupFlowScreen) -> [Row] {
        screen.actions.map { Row(event: $0.event, verdict: $0.verdict) }
    }

    private static func golden(_ kinds: Kinds, rigs: [SetupFlowRigID] = []) -> [Row] {
        var expected = [Row(event: .next, verdict: kinds.next), Row(event: .back, verdict: kinds.back)]
        for rig in rigs {
            expected.append(Row(event: .chooseRig(rig), verdict: kinds.choose))
        }
        expected.append(Row(event: .acknowledge(.home), verdict: kinds.home))
        expected.append(Row(event: .acknowledge(.runtimeMap), verdict: kinds.runtimeMap))
        expected.append(Row(event: .requestApply, verdict: kinds.apply))
        expected.append(Row(event: .stayManual, verdict: kinds.stay))
        expected.append(Row(event: .cancel, verdict: kinds.cancel))
        expected.append(Row(event: .reopen, verdict: kinds.reopen))
        return expected
    }

    private static func allRefused(_ refusal: SetupFlowRefusal, rigs: [SetupFlowRigID] = []) -> [Row] {
        let verdict = SetupFlowScreenVerdict.refused(refusal)
        let kinds = Kinds(
            next: verdict, back: verdict, choose: verdict, home: verdict, runtimeMap: verdict, apply: verdict,
            stay: verdict, cancel: verdict, reopen: verdict
        )
        return golden(kinds, rigs: rigs)
    }

    private static func direct(
        _ state: SetupFlowState,
        _ event: SetupFlowEvent,
        _ facts: SetupFlowFacts
    ) -> SetupFlowScreenVerdict {
        do throws(SetupFlowRefusal) {
            _ = try SetupFlowReducer.reduce(state, event, facts: facts)
            return .enabled
        } catch {
            return .refused(error)
        }
    }

    private static func manyRigs(_ count: Int) -> [SetupFlowRigID] {
        (0..<count).compactMap { SetupFlowRigID(rawValue: "rig.\($0)") }
    }

    private static func blocker(
        after events: [SetupFlowEvent],
        built: SetupFlowFacts,
        shown: SetupFlowFacts
    ) throws -> SetupFlowRefusal? {
        try screen(after: events, built: built, shown: shown).blocker
    }

    // MARK: - The action list

    @Test
    func setupFlowScreenAtBeginWithGoodFactsListsEightActionsWithTheReducerVerdicts() throws {
        let good = try Self.facts()
        let screen = try Self.screen(after: [], built: good)
        let expected = Self.golden(Kinds(
            back: .refused(.noPreviousStep), home: .refused(.wrongStep(expected: .review)),
            runtimeMap: .refused(.wrongStep(expected: .review)), apply: .refused(.wrongStep(expected: .decide))
        ))
        #expect(Self.rows(screen) == expected)
        let blocker: SetupFlowRefusal? = screen.blocker
        #expect(blocker == nil)
        #expect(screen.manual == .offered)
        #expect(screen.headline == "Step 1 of 4: identify your audio interface.")
        let phase: SetupFlowPhase = screen.phase
        #expect(phase == .running(.identify))
    }

    @Test
    func setupFlowScreenListsOfferedRigsInTheOrderGivenAndDoesNotSortThem() throws {
        let rigs = [Self.rigB, Self.rigA, Self.rigC]
        let screen = try Self.screen(after: [], built: try Self.facts(rigs: rigs))
        let events = screen.actions.map(\.event)
        let expected: [SetupFlowEvent] = [
            .next, .back, .chooseRig(Self.rigB), .chooseRig(Self.rigA), .chooseRig(Self.rigC),
            .acknowledge(.home), .acknowledge(.runtimeMap), .requestApply, .stayManual, .cancel, .reopen
        ]
        #expect(events == expected)
    }

    @Test
    func setupFlowScreenHoldsExactlyTwentyFourActionsAtSixteenRigsAndEightAtNone() throws {
        let sixteen = Self.manyRigs(16)
        #expect(sixteen.count == 16)
        let full = try Self.screen(after: [], built: try Self.facts(rigs: sixteen))
        #expect(full.actions.count == 24)
        let none = try Self.screen(after: [], built: try Self.facts())
        #expect(none.actions.count == 8)
        #expect(SetupFlowScreen.maximumActions == 24)
        let seventeen = Self.manyRigs(17)
        #expect(seventeen.count == 17)
        let refused = Self.makeRefusal(rigs: seventeen)
        let expected: SetupFlowRefusal? = .tooManyRigs(17)
        #expect(refused == expected)
    }

    private static func makeRefusal(rigs: [SetupFlowRigID]) -> SetupFlowRefusal? {
        do throws(SetupFlowRefusal) {
            _ = try SetupFlowFacts.make(
                access: .granted, presentDevices: 2, lostMuted: 0, offeredRigs: rigs, undecidedRoles: 0
            )
            return nil
        } catch {
            return error
        }
    }

    @Test
    func setupFlowScreenVerdictsEqualTheReducerForEveryStateAndFactsPair() throws {
        let good = try Self.facts()
        let states: [SetupFlowState] = try [
            Self.drive([], good), Self.drive(Self.path(to: .map), good), Self.drive(Self.path(to: .review), good),
            Self.drive(Self.path(to: .decide), good), Self.drive([.cancel], good), Self.drive([.stayManual], good)
        ]
        let shown: [SetupFlowFacts] = try [
            good, Self.facts(access: .denied), Self.facts(present: 0), Self.facts(roles: 2),
            Self.facts(rigs: [Self.rigA, Self.rigB])
        ]
        var compared = 0
        for state in states {
            for facts in shown {
                for action in SetupFlowScreen.make(state, facts: facts).actions {
                    let expected = Self.direct(state, action.event, facts)
                    #expect(action.verdict == expected)
                    compared += 1
                }
            }
        }
        #expect(compared == 252)
    }

    // MARK: - The blocker

    @Test
    func setupFlowScreenBlockerAtIdentifyFollowsTheGateOrderWithTwoDefectsInEachFixture() throws {
        let deniedNoDevice = try Self.facts(access: .denied, present: 0, rigs: [Self.rigA])
        let first = try Self.blocker(after: [], built: try Self.facts(), shown: deniedNoDevice)
        let expectedFirst: SetupFlowRefusal? = .permissionNotGranted(.denied)
        #expect(first == expectedFirst)
        let noDeviceNoPick = try Self.facts(present: 0, rigs: [Self.rigA])
        let second = try Self.blocker(after: [], built: try Self.facts(), shown: noDeviceNoPick)
        let expectedSecond: SetupFlowRefusal? = .noPresentDevice
        #expect(second == expectedSecond)
        let noPickRoles = try Self.facts(rigs: [Self.rigA], roles: 3)
        let third = try Self.blocker(after: [], built: try Self.facts(), shown: noPickRoles)
        let expectedThird: SetupFlowRefusal? = .rigNotChosen
        #expect(third == expectedThird)
    }

    @Test
    func setupFlowScreenBlockerAtMapNamesTheRigBeforeTheRolesAndThenTheRoles() throws {
        let good = try Self.facts()
        let map = Self.path(to: .map)
        let both = try Self.facts(rigs: [Self.rigA], roles: 3)
        let rig = try Self.blocker(after: map, built: good, shown: both)
        let expectedRig: SetupFlowRefusal? = .rigNotChosen
        #expect(rig == expectedRig)
        let roles = try Self.blocker(after: map, built: good, shown: try Self.facts(roles: 3))
        let expectedRoles: SetupFlowRefusal? = .rolesUndecided(3)
        #expect(roles == expectedRoles)
    }

    @Test
    func setupFlowScreenBlockerAtReviewNamesTheRolesThenTheHomePaneThenTheRuntimeMapPane() throws {
        let good = try Self.facts()
        let review = Self.path(to: .review)
        let rolesAndPanes = try Self.blocker(after: review, built: good, shown: try Self.facts(roles: 3))
        let expectedRoles: SetupFlowRefusal? = .rolesUndecided(3)
        #expect(rolesAndPanes == expectedRoles)
        let expectedHome: SetupFlowRefusal? = .paneNotReviewed(.home)
        let expectedMap: SetupFlowRefusal? = .paneNotReviewed(.runtimeMap)
        let none = try Self.blocker(after: review, built: good, shown: good)
        #expect(none == expectedHome)
        let onlyMap = try Self.blocker(after: review + [.acknowledge(.runtimeMap)], built: good, shown: good)
        #expect(onlyMap == expectedHome)
        let onlyHome = try Self.blocker(after: review + [.acknowledge(.home)], built: good, shown: good)
        #expect(onlyHome == expectedMap)
        let bothPanes = review + [.acknowledge(.home), .acknowledge(.runtimeMap)]
        let ready = try Self.screen(after: bothPanes, built: good)
        let readyBlocker: SetupFlowRefusal? = ready.blocker
        #expect(readyBlocker == nil)
        #expect(ready.blockerSentence == nil)
        let next = try Self.verdict(.next, in: ready)
        #expect(next == .enabled)
        let changed = try Self.blocker(after: bothPanes, built: good, shown: try Self.facts(present: 3))
        #expect(changed == expectedHome)
    }

    @Test
    func setupFlowScreenBlockerAtDecideComesFromRequestApplyAndNotFromNext() throws {
        let good = try Self.facts()
        let decide = Self.path(to: .decide)
        let ready = try Self.screen(after: decide, built: good)
        let readyBlocker: SetupFlowRefusal? = ready.blocker
        #expect(readyBlocker == nil)
        let apply = try Self.verdict(.requestApply, in: ready)
        #expect(apply == .enabled)
        let next = try Self.verdict(.next, in: ready)
        #expect(next == .refused(.noNextStep))
        let changed = try Self.blocker(after: decide, built: good, shown: try Self.facts(present: 3))
        let expected: SetupFlowRefusal? = .paneNotReviewed(.home)
        #expect(changed == expected)
    }

    @Test
    func setupFlowScreenKeepsAStalePickAsTheReducerJudgesItAndListsOnlyOfferedRigs() throws {
        let pick = try Self.drive([.chooseRig(Self.rigA)], try Self.facts(rigs: [Self.rigA, Self.rigB]))
        let narrowed = try Self.facts(rigs: [Self.rigB])
        let screen = SetupFlowScreen.make(pick, facts: narrowed)
        let expected: SetupFlowRefusal? = .rigNotOffered(Self.rigA)
        #expect(screen.blocker == expected)
        let next = try Self.verdict(.next, in: screen)
        #expect(next == .refused(.rigNotOffered(Self.rigA)))
        let events = screen.actions.map(\.event)
        let choices = events.filter { event in
            if case .chooseRig = event { return true }
            return false
        }
        #expect(choices == [.chooseRig(Self.rigB)])
        let phase: SetupFlowPhase = screen.phase
        #expect(phase == .running(.identify))
    }

    @Test
    func setupFlowScreenNeverPicksTheOnlyOfferedRigForTheOperator() throws {
        let one = try Self.facts(rigs: [Self.rigA])
        let screen = try Self.screen(after: [], built: one)
        let expected: SetupFlowRefusal? = .rigNotChosen
        #expect(screen.blocker == expected)
        let choose = try Self.verdict(.chooseRig(Self.rigA), in: screen)
        #expect(choose == .enabled)
        let after = try Self.screen(after: [.chooseRig(Self.rigA)], built: one)
        let afterBlocker: SetupFlowRefusal? = after.blocker
        #expect(afterBlocker == nil)
    }

    private static func verdict(_ event: SetupFlowEvent, in screen: SetupFlowScreen) throws -> SetupFlowScreenVerdict {
        let action = try #require(screen.actions.first { $0.event == event })
        return action.verdict
    }

    // MARK: - Manual, suspended and ended

    @Test
    func setupFlowScreenOffersManualAtEveryRunningStepAndWhileSuspendedUnderDeniedHardwareFacts() throws {
        let good = try Self.facts()
        let hostile = try Self.facts(access: .denied, present: 0, lost: 5, roles: 4)
        let steps: [SetupFlowStep] = [.identify, .map, .review, .decide]
        var shown: [SetupFlowScreen] = []
        for step in steps {
            shown.append(try Self.screen(after: Self.path(to: step), built: good, shown: hostile))
        }
        shown.append(try Self.screen(after: [.cancel], built: good, shown: hostile))
        #expect(shown.count == 5)
        for screen in shown {
            #expect(screen.manual == .offered)
            let stay = try Self.verdict(.stayManual, in: screen)
            #expect(stay == .enabled)
            #expect(screen.mutedNote == "Lost or muted devices stay muted. Setup makes no sound.")
            #expect(screen.manualSentence == "Stay manual to use manual or remote control without this setup.")
        }
        let atBegin = try #require(shown.first)
        let expected: SetupFlowRefusal? = .permissionNotGranted(.denied)
        #expect(atBegin.blocker == expected)
    }

    @Test
    func setupFlowScreenShowsManualActiveAndRefusesEveryActionOnceTheFlowEndedManual() throws {
        let hostile = try Self.facts(access: .denied, present: 0, lost: 5, roles: 4)
        let screen = try Self.screen(after: [.stayManual], built: try Self.facts(), shown: hostile)
        #expect(screen.manual == .active)
        #expect(screen.manualSentence == "Manual and remote control are in use.")
        #expect(screen.headline == "Setup ended. Manual and remote control stay available.")
        #expect(Self.rows(screen) == Self.allRefused(.flowEnded))
        let blocker: SetupFlowRefusal? = screen.blocker
        #expect(blocker == nil)
        #expect(screen.blockerSentence == nil)
        let phase: SetupFlowPhase = screen.phase
        #expect(phase == .ended(.manual))
    }

    @Test
    func setupFlowScreenShowsManualNotOfferedAndRefusesEveryActionOnceAnApplyWasRequested() throws {
        let good = try Self.facts()
        let screen = try Self.screen(after: Self.path(to: .decide) + [.requestApply], built: good)
        #expect(screen.manual == .notOffered)
        #expect(screen.manualSentence == "Manual mode is not part of this ending.")
        #expect(screen.headline == "Setup ended with a request to apply the setup.")
        #expect(Self.rows(screen) == Self.allRefused(.flowEnded))
        let blocker: SetupFlowRefusal? = screen.blocker
        #expect(blocker == nil)
        #expect(screen.blockerSentence == nil)
    }

    @Test
    func setupFlowScreenWhileSuspendedAcceptsOnlyReopenAndStayManualAtEveryStep() throws {
        let rigs = [Self.rigA]
        let built = try Self.facts(rigs: rigs)
        let steps: [SetupFlowStep] = [.identify, .map, .review, .decide]
        for step in steps {
            let screen = try Self.screen(after: Self.path(to: step, pick: Self.rigA) + [.cancel], built: built)
            let suspended = SetupFlowScreenVerdict.refused(.suspended)
            let kinds = Kinds(
                next: suspended, back: suspended, choose: suspended, home: suspended, runtimeMap: suspended,
                apply: suspended, cancel: suspended, reopen: .enabled
            )
            #expect(Self.rows(screen) == Self.golden(kinds, rigs: rigs))
            #expect(screen.headline == "Setup is paused. Reopen it or stay manual.")
            #expect(screen.manual == .offered)
            let blocker: SetupFlowRefusal? = screen.blocker
            #expect(blocker == nil)
            #expect(screen.blockerSentence == nil)
        }
    }

    // MARK: - Event fit per step

    @Test
    func setupFlowScreenFitsEachEventToItsStepAndKeepsBackAndNextAtTheEnds() throws {
        let rigs = [Self.rigA]
        let built = try Self.facts(rigs: rigs)
        let wrongIdentify = SetupFlowScreenVerdict.refused(.wrongStep(expected: .identify))
        let wrongReview = SetupFlowScreenVerdict.refused(.wrongStep(expected: .review))
        let wrongDecide = SetupFlowScreenVerdict.refused(.wrongStep(expected: .decide))
        let atIdentify = Kinds(
            back: .refused(.noPreviousStep), home: wrongReview, runtimeMap: wrongReview, apply: wrongDecide
        )
        let atMap = Kinds(
            next: .enabled, choose: wrongIdentify, home: wrongReview, runtimeMap: wrongReview, apply: wrongDecide
        )
        let atReview = Kinds(
            next: .refused(.paneNotReviewed(.home)), choose: wrongIdentify, apply: wrongDecide
        )
        let atDecide = Kinds(
            next: .refused(.noNextStep), choose: wrongIdentify, home: wrongReview, runtimeMap: wrongReview
        )
        let cases: [(SetupFlowStep, Kinds)] = [
            (.identify, atIdentify), (.map, atMap), (.review, atReview), (.decide, atDecide)
        ]
        for (step, kinds) in cases {
            let screen = try Self.screen(after: Self.path(to: step, pick: Self.rigA), built: built)
            #expect(Self.rows(screen) == Self.golden(kinds, rigs: rigs))
        }
        let decide = try Self.screen(after: Self.path(to: .decide, pick: Self.rigA), built: built)
        let blocker: SetupFlowRefusal? = decide.blocker
        #expect(blocker == nil)
    }
}
