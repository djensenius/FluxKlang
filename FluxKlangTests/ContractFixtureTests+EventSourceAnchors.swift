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

/// Every readable ledger field and every action's `ReadyAction`, for checking accepted events.
/// The private `restartPositionSuperseded` flag is left out: it only shows through a restart record,
/// a ledger with no pending restart refuses records, and the next primary bump resets the flag.
/// Use it only where `pendingRestart` is nil. Refusals use the full `EventSources` snapshot instead.
private struct NoRestartState: Equatable {
    let current: [GenerationKey: Generation]
    let pendingRestart: Generation?
    let restartRecord: ClockRestartRecord?
    let awaitingTransportBump: Bool
    let resume: TransportResume?
    let nominalRate: Int
    let actions: [ActionID: ReadyAction]

    init(_ ledger: GenerationLedger, _ readiness: ActionReadiness) {
        current = ledger.current
        pendingRestart = ledger.pendingRestart
        restartRecord = ledger.restartRecord
        awaitingTransportBump = ledger.awaitingTransportBump
        resume = ledger.resume
        nominalRate = ledger.nominalRate
        actions = Dictionary(uniqueKeysWithValues: readiness.states.keys.map { action in
            (action, ReadyAction(action, readiness, ledger))
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

        @Test func restartWithoutTransportCompletesWithItsRecord() throws {
            let ids = try Fixture.actions(1)
            var ledger = try GenerationLedger(primaryClock: ContractFixtureIDs.primaryClock, musicalClock: nil,
                                              nominalRate: Fixture.rate, declaring: [Fixture.context])
            var readiness = ActionReadiness()
            try Fixture.prepare(ids[0], on: [Fixture.context], ledger: ledger, readiness: &readiness)
            let ready = ReadyAction(ids[0], readiness, ledger)
            #expect(ready.state == .ready && ready.readyEntry == 1 && ready.invalidatedBy == [Fixture.context])

            let bumpStale = try FixtureEventApplier.apply(.bump(Fixture.primary, .deviceRestart), ledger: &ledger,
                                                          readiness: &readiness)
            #expect(bumpStale.isEmpty && ledger.hasRestartObligations && !ledger.awaitingTransportBump)
            let (record, anchor) = try Fixture.restartEvents()
            Fixture.expectRefusal(.firstAnchorRestartIncomplete, applying: .anchor(anchor, nominalRate: Fixture.rate),
                                  ledger: &ledger, readiness: &readiness)
            // There is no transport to bump, so the record alone completes the restart.
            Fixture.expectRefusal(.ledger(.undeclaredMusicalClock(Fixture.transport)),
                                  applying: .bump(Fixture.transport, .clockRestart),
                                  ledger: &ledger, readiness: &readiness)
            let recordStale = try FixtureEventApplier.apply(.restartRecord(record), ledger: &ledger,
                                                            readiness: &readiness)
            #expect(recordStale.isEmpty && ledger.restartRecord == record && !ledger.hasRestartObligations)
            #expect(ledger.resume == nil)
            let anchorStale = try FixtureEventApplier.apply(.anchor(anchor, nominalRate: Fixture.rate),
                                                            ledger: &ledger, readiness: &readiness)
            #expect(anchorStale.isEmpty && ReadyAction(ids[0], readiness, ledger) == ready)
        }

        @Test func transportBumpInvalidatesEveryTransportDependentSorted() throws {
            let ids = try Fixture.actions(3)
            var ledger = try Fixture.makeLedger()
            var readiness = ActionReadiness()
            // Prepared in reverse ID order, so a sorted result is not just insertion order.
            for id in [ids[1], ids[0]] {
                try Fixture.prepare(id, on: [Fixture.transport], ledger: ledger, readiness: &readiness)
            }
            try Fixture.prepare(ids[2], on: [Fixture.context], ledger: ledger, readiness: &readiness)
            let dependents = ids[0...1].map { ReadyAction($0, readiness, ledger) }
            #expect(dependents.allSatisfy { $0.state == .ready && $0.invalidatedBy == [Fixture.transport] })
            let unrelated = ReadyAction(ids[2], readiness, ledger)
            #expect(unrelated.state == .ready && unrelated.readyEntry == 1 && unrelated.isCurrent)

            let (record, _) = try Fixture.restartEvents()
            var source = try ScriptedEventSource(capacity: 3, events: [
                .bump(Fixture.primary, .deviceRestart), .restartRecord(record),
                .bump(Fixture.transport, .clockRestart)
            ])
            var stale: [[ActionID]] = []
            for _ in 0..<3 {
                let event = try Fixture.deliver(&source)
                stale.append(try FixtureEventApplier.apply(event, ledger: &ledger, readiness: &readiness))
            }
            #expect(stale == [[], [], [ids[0], ids[1]]] && !ledger.hasRestartObligations)
            for id in ids[0...1] {
                #expect(readiness.state(id) == .invalidated && readiness.reasons[id] == .sourceChanged)
            }
            #expect(ReadyAction(ids[2], readiness, ledger) == unrelated)
        }

        @Test func startingGenerationAnchorIsAcceptedAtAnyRate() throws {
            let ids = try Fixture.actions(1)
            var ledger = try Fixture.makeLedger()
            var readiness = ActionReadiness()
            try Fixture.prepare(ids[0], on: [Fixture.primary], ledger: ledger, readiness: &readiness)
            let before = NoRestartState(ledger, readiness)
            #expect(before.pendingRestart == nil && before.actions[ids[0]]?.state == .ready)
            #expect(before.actions[ids[0]]?.readyEntry == 1 && before.actions[ids[0]]?.isCurrent == true)

            // Fixture policy: the starting generation has no restart point, so its rate is not checked.
            var clock = try FixtureHostClock(startTicks: 0, step: 1_000_000)
            _ = try clock.tick()
            let anchor = clock.anchor(frame: 96, generation: .initial)
            let stale = try FixtureEventApplier.apply(.anchor(anchor, nominalRate: 96_000), ledger: &ledger,
                                                      readiness: &readiness)
            #expect(stale.isEmpty && NoRestartState(ledger, readiness) == before)
            #expect(ledger.nominalRate == Fixture.rate)
        }

        @Test func anchorAfterADroppedPrimaryBumpIsStale() throws {
            let ids = try Fixture.actions(1)
            var ledger = try Fixture.makeLedger()
            var readiness = ActionReadiness()
            try Fixture.prepare(ids[0], on: [Fixture.primary], ledger: ledger, readiness: &readiness)
            let ready = ReadyAction(ids[0], readiness, ledger)
            #expect(ready.state == .ready && ready.readyEntry == 1 && ready.isCurrent)

            // The anchor belongs to generation 2, but the bump that would start it is lost.
            let (_, anchor) = try Fixture.restartEvents()
            let bump = ContractFixtureEvent.bump(Fixture.primary, .deviceRestart)
            let newer = ContractFixtureEvent.anchor(anchor, nominalRate: Fixture.rate)
            var source = try ScriptedEventSource(capacity: 2, events: [bump, newer])
            try source.inject(.drop)
            #expect(source.pending == [newer] && source.lost.entries == [bump])
            #expect(source.droppedCount == 1 && source.overflowCount == 0 && source.deliveredCount == 0)

            let delivered = try Fixture.deliver(&source)
            #expect(delivered == newer && source.deliveredCount == 1 && source.next() == nil)
            #expect(ledger.pendingRestart == nil && ledger.generation(Fixture.primary) == .initial)
            #expect(anchor.sample.generation == (try Generation.initial.next()))
            Fixture.expectRefusal(.staleAnchor, applying: delivered, ledger: &ledger, readiness: &readiness)
            #expect(ReadyAction(ids[0], readiness, ledger) == ready)
        }
    }
}
