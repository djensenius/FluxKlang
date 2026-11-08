import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformRecallTests {
    @Test func performRecallAnEqualEpochIsFreshAtGenerationOneAndAtTheMaximumGeneration() throws {
        let maximum = try Self.epochAt(Generation.maximumValue)
        let epochs = [Self.epochA, maximum]
        for epoch in epochs {
            let facts = Self.facts(.hazardous).epoched(epoch)
            let confirmed = Self.step(.awaitingConfirm(epoch), .confirm, facts)
            #expect(confirmed.phase == .fired(epoch))
            #expect(Self.isFire(confirmed))
            let repeated = Self.step(.fired(epoch), .press, facts)
            Self.expectStep(repeated, .fired(epoch), .refused(.alreadyFired))
        }
    }

    @Test func performRecallALowerAHigherAndAnotherHostEpochAreStaleAndDropToIdle() throws {
        let maximum = try Self.epochAt(Generation.maximumValue)
        let belowMaximum = try Self.epochAt(Generation.maximumValue - 1)
        let two = try Self.epochAt(2)
        let heldAndLive: [(HostEpoch, HostEpoch)] = [
            (Self.epochA, two), (two, Self.epochA), (Self.epochA, Self.epochOtherHost),
            (belowMaximum, maximum), (maximum, belowMaximum)
        ]
        for (held, live) in heldAndLive {
            let awaiting = PerformRecallPhase.awaitingConfirm(held)
            let fired = PerformRecallPhase.fired(held)
            let phasesAndEvents: [(PerformRecallPhase, PerformRecallEvent)] = [
                (awaiting, .press), (awaiting, .confirm), (fired, .press), (fired, .confirm)
            ]
            for (phase, event) in phasesAndEvents {
                let outcome = Self.step(phase, event, Self.facts(.live).epoched(live))
                Self.expectStep(outcome, .idle, .dropped(.staleEpoch))
            }
        }
    }

    @Test func performRecallIdlePressFiresUnderEachOfThreeEpochsTheFactsCarry() throws {
        let maximum = try Self.epochAt(Generation.maximumValue)
        let epochs = [Self.epochA, Self.epochOtherHost, maximum]
        for epoch in epochs {
            let outcome = Self.step(.idle, .press, Self.facts(.live).epoched(epoch))
            #expect(outcome.phase == .fired(epoch))
            #expect(Self.isFire(outcome))
        }
    }

    @Test func performRecallAPressAfterAStaleDropFiresUnderTheNewEpoch() throws {
        let newer = try Self.epochAt(2)
        let facts = Self.facts(.live).epoched(newer)
        let dropped = Self.step(.fired(Self.epochA), .press, facts)
        Self.expectStep(dropped, .idle, .dropped(.staleEpoch))
        let next = Self.step(dropped.phase, .press, facts)
        #expect(next.phase == .fired(newer))
        let intent = try Self.intent(of: next)
        #expect(intent.epoch == newer)
    }

    @Test func performRecallResyncingDropsPressAndConfirmFromIdleAwaitingConfirmAndFired() {
        let facts = Self.facts(.live).resynced()
        for (phase, event) in Self.phaseAndEvent {
            Self.expectStep(Self.step(phase, event, facts), .idle, .dropped(.resyncing))
        }
    }

    @Test func performRecallAStaleAwaitingConfirmIsDroppedSoALaterConfirmAtIdleIsRefused() {
        let staleFacts = Self.facts(.hazardous).epoched(Self.epochOtherHost)
        let dropped = Self.step(.awaitingConfirm(Self.epochA), .confirm, staleFacts)
        Self.expectStep(dropped, .idle, .dropped(.staleEpoch))
        let later = Self.step(dropped.phase, .confirm, Self.facts(.hazardous))
        Self.expectStep(later, .idle, .refused(.notAwaitingConfirm))
    }
}
