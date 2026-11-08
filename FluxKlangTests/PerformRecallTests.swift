import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct PerformRecallNoFire: Error {}

/// One phase with the event applied to it, and the refusal a phase conflict gives.
struct PerformRecallConflictCase: Sendable {
    let phase: PerformRecallPhase
    let event: PerformRecallEvent
    let refusal: PerformRecallRefusal
}

extension PerformRecallFacts {
    func resynced() -> PerformRecallFacts {
        PerformRecallFacts(epoch: epoch, resyncing: true, permitted: permitted, targetExists: targetExists,
                           controlClass: controlClass, readiness: readiness)
    }

    func unpermitted() -> PerformRecallFacts {
        PerformRecallFacts(epoch: epoch, resyncing: resyncing, permitted: false, targetExists: targetExists,
                           controlClass: controlClass, readiness: readiness)
    }

    func targetless() -> PerformRecallFacts {
        PerformRecallFacts(epoch: epoch, resyncing: resyncing, permitted: permitted, targetExists: false,
                           controlClass: controlClass, readiness: readiness)
    }

    func readied(_ state: ReadinessState) -> PerformRecallFacts {
        PerformRecallFacts(epoch: epoch, resyncing: resyncing, permitted: permitted, targetExists: targetExists,
                           controlClass: controlClass, readiness: state)
    }

    func epoched(_ newEpoch: HostEpoch) -> PerformRecallFacts {
        PerformRecallFacts(epoch: newEpoch, resyncing: resyncing, permitted: permitted, targetExists: targetExists,
                           controlClass: controlClass, readiness: readiness)
    }
}

@Suite("Perform recall cell reducer (#102 RCL1)")
struct PerformRecallTests {
    static let epochA = HostEpoch(host: HostID(validated: "host.a"), generation: Generation.initial)
    static let epochOtherHost = HostEpoch(host: HostID(validated: "host.b"), generation: Generation.initial)
    static let baseline = PerformRecallTarget(patch: PatchID(validated: "pat.verse"), variation: nil)
    static let chorus = PerformRecallTarget(
        patch: PatchID(validated: "pat.verse"), variation: PerformRecallVariationID(validated: "var.chorus")
    )

    static func epochAt(_ generation: Int) throws -> HostEpoch {
        HostEpoch(host: HostID(validated: "host.a"), generation: try Generation(generation))
    }

    /// Facts that pass every gate other than the class gate: fresh epoch, not resyncing, permitted, target present,
    /// ready.
    static func facts(_ controlClass: ControlClass = .live) -> PerformRecallFacts {
        PerformRecallFacts(epoch: epochA, resyncing: false, permitted: true, targetExists: true,
                           controlClass: controlClass, readiness: .ready)
    }

    static func step(
        _ phase: PerformRecallPhase,
        _ event: PerformRecallEvent,
        _ facts: PerformRecallFacts,
        target: PerformRecallTarget = PerformRecallTests.baseline
    ) -> PerformRecallStep {
        PerformRecallReducer.reduce(phase, event, target: target, facts: facts)
    }

    static func expectStep(
        _ step: PerformRecallStep,
        _ phase: PerformRecallPhase,
        _ decision: PerformRecallDecision,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(step.phase == phase, sourceLocation: sourceLocation)
        #expect(step.decision == decision, sourceLocation: sourceLocation)
    }

    static func isFire(_ step: PerformRecallStep) -> Bool {
        if case .fire = step.decision { return true }
        return false
    }

    static func intent(of step: PerformRecallStep) throws -> PerformRecallIntent {
        guard case .fire(let intent) = step.decision else { throw PerformRecallNoFire() }
        return intent
    }

    static let conflicts: [PerformRecallConflictCase] = [
        PerformRecallConflictCase(phase: .awaitingConfirm(epochA), event: .press, refusal: .alreadyAwaitingConfirm),
        PerformRecallConflictCase(phase: .fired(epochA), event: .press, refusal: .alreadyFired),
        PerformRecallConflictCase(phase: .idle, event: .confirm, refusal: .notAwaitingConfirm),
        PerformRecallConflictCase(phase: .fired(epochA), event: .confirm, refusal: .alreadyFired)
    ]

    /// Every phase with press and with confirm, the awaiting and fired phases hold the live epoch `epochA`.
    static let phaseAndEvent: [(PerformRecallPhase, PerformRecallEvent)] = [
        (.idle, .press), (.idle, .confirm),
        (.awaitingConfirm(epochA), .press), (.awaitingConfirm(epochA), .confirm),
        (.fired(epochA), .press), (.fired(epochA), .confirm)
    ]

    @Test func performRecallLiveWalkFiresRefusesARepeatReleasesOnSettleAndFiresAgain() throws {
        let facts = Self.facts(.live)
        let first = Self.step(.idle, .press, facts)
        #expect(first.phase == .fired(Self.epochA))
        _ = try Self.intent(of: first)
        let repeated = Self.step(first.phase, .press, facts)
        Self.expectStep(repeated, .fired(Self.epochA), .refused(.alreadyFired))
        let settled = Self.step(repeated.phase, .settle, facts)
        Self.expectStep(settled, .idle, .released)
        let second = Self.step(settled.phase, .press, facts)
        #expect(second.phase == .fired(Self.epochA))
        _ = try Self.intent(of: second)
    }

    @Test func performRecallHazardousWalkAsksRefusesARepeatConfirmsRefusesAConfirmAgainAndSettles() throws {
        let facts = Self.facts(.hazardous)
        let asked = Self.step(.idle, .press, facts)
        Self.expectStep(asked, .awaitingConfirm(Self.epochA), .awaitConfirm)
        let repeated = Self.step(asked.phase, .press, facts)
        Self.expectStep(repeated, .awaitingConfirm(Self.epochA), .refused(.alreadyAwaitingConfirm))
        let confirmed = Self.step(repeated.phase, .confirm, facts)
        #expect(confirmed.phase == .fired(Self.epochA))
        _ = try Self.intent(of: confirmed)
        let again = Self.step(confirmed.phase, .confirm, facts)
        Self.expectStep(again, .fired(Self.epochA), .refused(.alreadyFired))
        let settled = Self.step(again.phase, .settle, facts)
        Self.expectStep(settled, .idle, .released)
    }

    @Test func performRecallPressAtIdleFiresLiveAsksHazardousAndRefusesTheOtherThreeClasses() {
        for controlClass in ControlClass.allCases {
            let outcome = Self.step(.idle, .press, Self.facts(controlClass))
            switch controlClass {
            case .live:
                #expect(outcome.phase == .fired(Self.epochA))
                #expect(Self.isFire(outcome))
            case .hazardous:
                Self.expectStep(outcome, .awaitingConfirm(Self.epochA), .awaitConfirm)
            case .structural, .safety, .proposal:
                Self.expectStep(outcome, .idle, .refused(.classNotPerformable(controlClass)))
            }
        }
    }

    @Test func performRecallConfirmAtAwaitingConfirmFiresForLiveAndHazardousAndRefusesTheOtherThreeClasses() {
        for controlClass in ControlClass.allCases {
            let outcome = Self.step(.awaitingConfirm(Self.epochA), .confirm, Self.facts(controlClass))
            switch controlClass {
            case .live, .hazardous:
                #expect(outcome.phase == .fired(Self.epochA))
                #expect(Self.isFire(outcome))
            case .structural, .safety, .proposal:
                Self.expectStep(outcome, .awaitingConfirm(Self.epochA), .refused(.classNotPerformable(controlClass)))
            }
        }
    }

    @Test func performRecallPressAtIdleOnlyFiresWhenReadinessIsReadyAndDropsTheOtherFourWithTheirState() {
        for state in ReadinessState.allCases {
            let outcome = Self.step(.idle, .press, Self.facts(.live).readied(state))
            if state == .ready {
                #expect(Self.isFire(outcome))
            } else {
                Self.expectStep(outcome, .idle, .dropped(.notReady(state)))
            }
        }
    }

    @Test func performRecallConfirmOnlyFiresWhenReadinessIsReadyAndDropsTheOtherFourWithTheirState() {
        for state in ReadinessState.allCases {
            let outcome = Self.step(.awaitingConfirm(Self.epochA), .confirm, Self.facts(.hazardous).readied(state))
            if state == .ready {
                #expect(Self.isFire(outcome))
            } else {
                Self.expectStep(outcome, .idle, .dropped(.notReady(state)))
            }
        }
    }

    @Test func performRecallConfirmAtIdleIsRefusedForLiveAndHazardousAndKeepsIdle() {
        let live = Self.step(.idle, .confirm, Self.facts(.live))
        Self.expectStep(live, .idle, .refused(.notAwaitingConfirm))
        let hazardous = Self.step(.idle, .confirm, Self.facts(.hazardous))
        Self.expectStep(hazardous, .idle, .refused(.notAwaitingConfirm))
    }

    @Test func performRecallNotPermittedNoTargetAndAStructuralClassAreEachRefusedAlone() {
        let notPermitted = Self.step(.idle, .press, Self.facts(.live).unpermitted())
        Self.expectStep(notPermitted, .idle, .refused(.notPermitted))
        let noTarget = Self.step(.idle, .press, Self.facts(.live).targetless())
        Self.expectStep(noTarget, .idle, .refused(.noTarget))
        let structural = Self.step(.idle, .press, Self.facts(.structural))
        Self.expectStep(structural, .idle, .refused(.classNotPerformable(.structural)))
    }

    @Test func performRecallAHazardousPressGivesNoFireFromIdleAwaitingConfirmAndFiredUnderFreshReadyFacts() {
        let facts = Self.facts(.hazardous)
        let fromIdle = Self.step(.idle, .press, facts)
        #expect(!Self.isFire(fromIdle))
        let fromAwaiting = Self.step(.awaitingConfirm(Self.epochA), .press, facts)
        #expect(!Self.isFire(fromAwaiting))
        let fromFired = Self.step(.fired(Self.epochA), .press, facts)
        #expect(!Self.isFire(fromFired))
    }

    @Test func performRecallTheIntentCarriesTheTargetTheFactsClassAndTheFactsEpochWithAndWithoutAVariation() throws {
        let baselineIntent = try Self.intent(of: Self.step(.idle, .press, Self.facts(.live), target: Self.baseline))
        #expect(baselineIntent.target == Self.baseline)
        #expect(baselineIntent.controlClass == .live)
        #expect(baselineIntent.epoch == Self.epochA)
        let chorusIntent = try Self.intent(of: Self.step(.idle, .press, Self.facts(.live), target: Self.chorus))
        #expect(chorusIntent.target == Self.chorus)
    }

    @Test func performRecallAConfirmReadsTheClassFromTheFactsItIsGivenNotFromTheHazardousPress() throws {
        let asked = Self.step(.idle, .press, Self.facts(.hazardous))
        let asLive = try Self.intent(of: Self.step(asked.phase, .confirm, Self.facts(.live)))
        #expect(asLive.controlClass == .live)
        let hazardousStep = Self.step(asked.phase, .confirm, Self.facts(.hazardous), target: Self.chorus)
        let asHazardous = try Self.intent(of: hazardousStep)
        #expect(asHazardous.controlClass == .hazardous)
        #expect(asHazardous.target == Self.chorus)
    }

    @Test func performRecallPressAndConfirmRecordTheFactsEpochForAnotherHostAndForTheMaximumGeneration() throws {
        let maximum = try Self.epochAt(Generation.maximumValue)
        let hosts = [Self.epochOtherHost, maximum]
        for epoch in hosts {
            let asked = Self.step(.idle, .press, Self.facts(.hazardous).epoched(epoch))
            Self.expectStep(asked, .awaitingConfirm(epoch), .awaitConfirm)
            let confirmed = Self.step(asked.phase, .confirm, Self.facts(.hazardous).epoched(epoch))
            #expect(confirmed.phase == .fired(epoch))
            let intent = try Self.intent(of: confirmed)
            #expect(intent.epoch == epoch)
        }
    }

    @Test func performRecallAStepHoldsTwoStoredMembersAndAnIntentThree() throws {
        let step = Self.step(.idle, .press, Self.facts(.live))
        let stepMembers = Mirror(reflecting: step).children.count
        #expect(stepMembers == 2)
        let intentMembers = Mirror(reflecting: try Self.intent(of: step)).children.count
        #expect(intentMembers == 3)
    }
}
