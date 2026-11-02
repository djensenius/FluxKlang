import Testing
@testable import FluxKlang

private typealias Fixture = ContractFixtureTests.EventSources

/// What readiness exposes about one action. Dependencies are read through `generationChanged`
/// on a copy for every ledger counter, so taking the snapshot mutates nothing.
private struct ReadyAction: Equatable {
    let state: ReadinessState
    let reason: ReadinessReason?
    let readyEntry: Int?
    let isCurrent: Bool
    let invalidatedBy: Set<GenerationKey>

    init(_ action: ActionID, _ readiness: ActionReadiness, _ ledger: GenerationLedger) {
        state = readiness.state(action)
        reason = readiness.reasons[action]
        readyEntry = readiness.readyEntry(action)
        isCurrent = readiness.isCurrent(action, ledger: ledger)
        invalidatedBy = Set(ledger.current.keys.filter { key in
            var probe = readiness
            return probe.generationChanged(key).contains(action)
        })
    }
}

extension ContractFixtureTests {
    /// Restart-record and anchor events through the real applier, each anchor checked on its own as a
    /// first-anchor candidate. Setup and refusal checks are shared with `EventSources`.
    struct EventSourceAnchors {
        @Test func rateChangeSetsTheRateItsFirstAnchorIsCheckedAt() throws {
            let newRate = 96_000
            var ledger = try Fixture.makeLedger()
            var readiness = ActionReadiness()
            let ids = try Fixture.actions(1)
            try Fixture.prepare(ids[0], on: [Fixture.primary], ledger: ledger, readiness: &readiness)
            let bumpStale = try FixtureEventApplier.apply(.bump(Fixture.primary, .rateChange(nominalRate: newRate)),
                                                          ledger: &ledger, readiness: &readiness)
            let restarted = try #require(ledger.pendingRestart)
            #expect(bumpStale == ids && ledger.nominalRate == newRate && restarted.value == 2)
            #expect(readiness.state(ids[0]) == .invalidated && readiness.reasons[ids[0]] == .sourceChanged)

            // One second after the restart point: 96,000 frames at the new rate, 48,000 at the old one.
            var clock = try FixtureHostClock(startTicks: 0, step: 1_000_000_000)
            let start = SampleStamp(clock: ContractFixtureIDs.primaryClock, generation: restarted, frame: 0)
            let record = ClockRestartRecord(start: start, host: try clock.tick(), previousFrame: 0)
            try FixtureEventApplier.apply(.restartRecord(record), ledger: &ledger, readiness: &readiness)
            try FixtureEventApplier.apply(.bump(Fixture.transport, .clockRestart), ledger: &ledger,
                                          readiness: &readiness)
            _ = try clock.tick()
            let atNewRate = clock.anchor(frame: 96_000, generation: restarted)
            let atOldRate = clock.anchor(frame: 48_000, generation: restarted)
            Fixture.expectRefusal(.firstAnchorRejected, applying: .anchor(atNewRate, nominalRate: Fixture.rate),
                                  ledger: &ledger, readiness: &readiness)
            Fixture.expectRefusal(.firstAnchorRejected, applying: .anchor(atOldRate, nominalRate: newRate),
                                  ledger: &ledger, readiness: &readiness)
            // The only action is already invalidated here; that accepted anchors preserve a ready
            // action is shown by `recordFirstRestartKeepsAnUnaffectedReadyActionReady`.
            let anchorStale = try FixtureEventApplier.apply(.anchor(atNewRate, nominalRate: newRate),
                                                            ledger: &ledger, readiness: &readiness)
            #expect(anchorStale.isEmpty && ledger.nominalRate == newRate)
        }

        @Test func recordFirstRestartKeepsAnUnaffectedReadyActionReady() throws {
            let ids = try Fixture.actions(1)
            var ledger = try Fixture.makeLedger()
            var readiness = ActionReadiness()
            try Fixture.prepare(ids[0], on: [Fixture.context], ledger: ledger, readiness: &readiness)
            let ready = ReadyAction(ids[0], readiness, ledger)
            #expect(ready.state == .ready && ready.readyEntry == 1 && ready.isCurrent)
            #expect(ready.invalidatedBy == [Fixture.context])

            let bumpStale = try FixtureEventApplier.apply(.bump(Fixture.primary, .deviceRestart), ledger: &ledger,
                                                          readiness: &readiness)
            #expect(bumpStale.isEmpty && ReadyAction(ids[0], readiness, ledger) == ready)
            // Refusals change nothing at all, the ready action included (full snapshot).
            let (record, anchor) = try Fixture.restartEvents()
            let stale = SampleStamp(clock: ContractFixtureIDs.primaryClock, generation: .initial, frame: 0)
            let mismatched = ClockRestartRecord(start: stale, host: record.host, previousFrame: 0)
            Fixture.expectRefusal(.ledger(.restartGenerationMismatch), applying: .restartRecord(mismatched),
                                  ledger: &ledger, readiness: &readiness)

            // The record arrives first: the anchor still waits for the transport bump.
            let recordStale = try FixtureEventApplier.apply(.restartRecord(record), ledger: &ledger,
                                                            readiness: &readiness)
            #expect(recordStale.isEmpty && ledger.restartRecord == record && ledger.awaitingTransportBump)
            #expect(ledger.hasRestartObligations && ReadyAction(ids[0], readiness, ledger) == ready)
            Fixture.expectRefusal(.firstAnchorRestartIncomplete, applying: .anchor(anchor, nominalRate: Fixture.rate),
                                  ledger: &ledger, readiness: &readiness)
            Fixture.expectRefusal(.ledger(.restartAlreadyRecorded), applying: .restartRecord(record),
                                  ledger: &ledger, readiness: &readiness)

            let transportStale = try FixtureEventApplier.apply(.bump(Fixture.transport, .clockRestart),
                                                               ledger: &ledger, readiness: &readiness)
            #expect(transportStale.isEmpty && !ledger.hasRestartObligations)
            Fixture.expectRefusal(.firstAnchorRejected, applying: .anchor(anchor, nominalRate: 96_000),
                                  ledger: &ledger, readiness: &readiness)
            let anchorStale = try FixtureEventApplier.apply(.anchor(anchor, nominalRate: Fixture.rate),
                                                            ledger: &ledger, readiness: &readiness)
            #expect(anchorStale.isEmpty && ReadyAction(ids[0], readiness, ledger) == ready)
        }
    }
}
