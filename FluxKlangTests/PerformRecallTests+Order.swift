import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformRecallTests {
    static let staleEpochFacts = PerformRecallTests.facts(.live).epoched(PerformRecallTests.epochOtherHost)

    /// Phases that hold the live epoch `epochA`, with press and confirm; each can be made stale.
    static let heldPhaseAndEvent: [(PerformRecallPhase, PerformRecallEvent)] = [
        (.awaitingConfirm(epochA), .press), (.awaitingConfirm(epochA), .confirm),
        (.fired(epochA), .press), (.fired(epochA), .confirm)
    ]

    @Test func performRecallResyncingIsReportedBeforeAStaleEpochWhenBothHold() {
        let facts = Self.staleEpochFacts.resynced()
        for (phase, event) in Self.heldPhaseAndEvent {
            Self.expectStep(Self.step(phase, event, facts), .idle, .dropped(.resyncing))
        }
    }

    @Test func performRecallAStaleEpochIsReportedBeforeNotPermittedWhenBothHold() {
        let facts = Self.staleEpochFacts.unpermitted()
        for (phase, event) in Self.heldPhaseAndEvent {
            Self.expectStep(Self.step(phase, event, facts), .idle, .dropped(.staleEpoch))
        }
    }

    @Test func performRecallNotPermittedIsReportedBeforeNoTargetWhenBothHold() {
        let facts = Self.facts(.live).unpermitted().targetless()
        for (phase, event) in Self.phaseAndEvent {
            Self.expectStep(Self.step(phase, event, facts), phase, .refused(.notPermitted))
        }
    }

    @Test func performRecallNoTargetIsReportedBeforeAStructuralClassWhenBothHold() {
        let facts = Self.facts(.structural).targetless()
        for (phase, event) in Self.phaseAndEvent {
            Self.expectStep(Self.step(phase, event, facts), phase, .refused(.noTarget))
        }
    }

    @Test func performRecallAStructuralClassIsReportedBeforeEachPhaseConflictWhenBothHold() {
        let classes: [ControlClass] = [.structural, .safety, .proposal]
        for conflict in Self.conflicts {
            for controlClass in classes {
                let outcome = Self.step(conflict.phase, conflict.event, Self.facts(controlClass))
                Self.expectStep(outcome, conflict.phase, .refused(.classNotPerformable(controlClass)))
            }
        }
    }

    @Test func performRecallEachPhaseConflictIsReportedBeforeAnyNotReadyStateWhenBothHold() {
        let classes: [ControlClass] = [.live, .hazardous]
        let notReady: [ReadinessState] = [.unprepared, .preparing, .invalidated, .failed]
        for conflict in Self.conflicts {
            for controlClass in classes {
                for state in notReady {
                    let facts = Self.facts(controlClass).readied(state)
                    let outcome = Self.step(conflict.phase, conflict.event, facts)
                    Self.expectStep(outcome, conflict.phase, .refused(conflict.refusal))
                }
            }
        }
    }

    @Test func performRecallEachPhaseConflictIsRefusedAndKeepsItsPhaseUnderReadyFacts() {
        for conflict in Self.conflicts {
            let outcome = Self.step(conflict.phase, conflict.event, Self.facts(.live))
            Self.expectStep(outcome, conflict.phase, .refused(conflict.refusal))
        }
    }

    @Test func performRecallNotPermittedNoTargetAndStructuralRefusalsKeepEachPhaseAndResyncAndStaleDropsSetIdle() {
        let refusing: [PerformRecallFacts] = [
            Self.facts(.live).unpermitted(), Self.facts(.live).targetless(), Self.facts(.structural)
        ]
        for facts in refusing {
            for (phase, event) in Self.phaseAndEvent {
                let outcome = Self.step(phase, event, facts)
                #expect(outcome.phase == phase)
            }
        }
        let dropping: [PerformRecallFacts] = [
            Self.facts(.live).resynced(), Self.staleEpochFacts
        ]
        for facts in dropping {
            for (phase, event) in Self.heldPhaseAndEvent {
                let outcome = Self.step(phase, event, facts)
                #expect(outcome.phase == .idle)
            }
        }
    }
}
