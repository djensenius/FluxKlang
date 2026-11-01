//
//  FixtureEventApplier.swift
//  FluxKlangTests
//
//  Applies one scripted event to a generation ledger and action readiness
//  through their accepted contract APIs only. A refused event leaves both
//  values unchanged.
//

@testable import FluxKlang

/// Why an event was refused. A refusal changes neither the ledger nor readiness.
enum FixtureEventError: Error, Equatable, Sendable {
    /// The ledger refused the bump or restart record.
    case ledger(GenerationLedgerError)
    /// The anchor is not on the ledger's primary sample clock.
    case anchorOffPrimaryClock
    /// The anchor is on a primary clock generation that is not current.
    case staleAnchor
    /// Fixture policy: the current generation's clock restart still lacks its record or
    /// transport bump, so its first anchor cannot be checked yet.
    case firstAnchorRestartIncomplete
    /// `GenerationLedger.acceptsFirstAnchor` refused the anchor: it disagrees with the restart
    /// point (§5.3 step 4) or was observed at a rate other than the ledger's.
    case firstAnchorRejected
}

enum FixtureEventApplier {
    /// Applies `event` and returns the actions it made stale, sorted.
    ///
    /// A bump invalidates every ready action that depends on its counter. A restart
    /// record and an accepted anchor make nothing stale.
    ///
    /// Anchors follow a fixture policy for the *first* anchor of a generation only:
    /// it must be on the primary clock's current generation, and if that generation
    /// began with a clock restart, `GenerationLedger.acceptsFirstAnchor` must accept it
    /// at the event's `nominalRate`. There are no ordering, drift or declared-rate checks
    /// for later anchors, and none at all on the starting generation; that is
    /// `SchedulerClock.observe`'s job, left for the scheduler fixtures (F8).
    @discardableResult
    static func apply(
        _ event: ContractFixtureEvent,
        ledger: inout GenerationLedger,
        readiness: inout ActionReadiness,
        timebase: HostTimebase = HostTimebase(numer: 1, denom: 1)
    ) throws(FixtureEventError) -> [ActionID] {
        switch event {
        case let .bump(key, reason):
            do { try ledger.bump(key, reason: reason) } catch { throw .ledger(error) }
            return readiness.generationChanged(key)
        case .restartRecord(let record):
            do { try ledger.recordClockRestart(record) } catch { throw .ledger(error) }
            return []
        case let .anchor(anchor, nominalRate):
            try validateFirstAnchor(anchor, nominalRate: nominalRate, ledger: ledger, timebase: timebase)
            return []
        }
    }

    /// Fixture policy for a generation's first anchor; see `apply`.
    private static func validateFirstAnchor(_ anchor: ClockAnchor, nominalRate: Int, ledger: GenerationLedger,
                                            timebase: HostTimebase) throws(FixtureEventError) {
        guard GenerationKey(.sampleClock, anchor.sample.clock) == ledger.primaryClock else {
            throw .anchorOffPrimaryClock
        }
        let current = ledger.generation(ledger.primaryClock)
        guard anchor.sample.generation == current else { throw .staleAnchor }
        guard ledger.pendingRestart == current else { return }
        guard !ledger.hasRestartObligations else { throw .firstAnchorRestartIncomplete }
        guard ledger.acceptsFirstAnchor(anchor, nominalRate: nominalRate, timebase: timebase) else {
            throw .firstAnchorRejected
        }
    }
}
