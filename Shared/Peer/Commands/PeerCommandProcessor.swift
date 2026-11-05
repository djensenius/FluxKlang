//
//  PeerCommandProcessor.swift
//  FluxKlang
//
//  Host-side admission of one session's command envelopes (#95). Order:
//  1. freshness: the live epochs must still be this session's, and the intent's
//     host and connection epochs must equal them, so an old epoch is refused
//     even for an absolute setter or a safety command;
//  2. the per-session envelope sequence (a break latches the session failed);
//  3. the dedup ledger, which only replays and never admits: a duplicate gets
//     its recorded outcome, or `inFlight`, and only while the current
//     permission fingerprint equals the one it was admitted under;
//  4. for a new command, ledger capacity and then `CommandAdmission.admit`,
//     unchanged, including its all-or-nothing revision check.
//  Idempotence is not freshness: a changed patch or context needs a fresh
//  intent with a new command ID. Authorization stays abstract here: the
//  caller supplies the permission fingerprint, scopes and classes (#94).
//
//  Only admitted commands are remembered. A refusal is never recorded, because
//  it may be transient (a full ledger, a stale context, a resync) and the
//  ledger never admits; a retried ID that was refused is evaluated fresh, from
//  step 1. First-result replay therefore applies to admitted commands only.
//

import Foundation

struct PeerCommandProcessor: Sendable {
    let session: PeerSyncSession
    private(set) var ledger: PeerCommandLedger
    private(set) var expectedSequence: PeerSequence?
    private(set) var hasFailed = false

    init(session: PeerSyncSession,
         ledgerCapacity: Int = PeerCommandLedger.standardCapacity) throws(PeerCommandCapacityError) {
        self.session = session
        ledger = try PeerCommandLedger(connectionEpoch: session.connectionEpoch, capacity: ledgerCapacity)
        expectedSequence = try? PeerSequence.origin.next()
    }

    /// Decides one envelope against the live `admission` context. Refusals are
    /// returned, not recorded; only `.admitted` reserves a ledger entry.
    mutating func process(_ envelope: PeerCommandEnvelope, admission: AdmissionContext) -> PeerCommandResult {
        let intent = envelope.intent
        let sequenceRefusal = consume(envelope.sequence)
        func result(_ outcome: PeerCommandOutcome) -> PeerCommandResult {
            PeerCommandResult(sequence: envelope.sequence, command: intent.id, outcome: outcome)
        }
        if let retired = session.staleDependency(host: admission.hostEpoch, connection: admission.connectionEpoch) {
            return result(.refused(.sessionRetired(retired)))
        }
        if let stale = session.staleDependency(host: intent.hostEpoch, connection: intent.connectionEpoch) {
            return result(.refused(.command(.stale(stale))))
        }
        if let sequenceRefusal { return result(.refused(sequenceRefusal)) }
        if let entry = ledger.entry(for: intent.id) {
            return result(replay(entry, intent: intent, admission: admission))
        }
        guard !ledger.isFull else { return result(.refused(.ledgerFull(capacity: ledger.capacity))) }
        if case .refused(let refusal) = CommandAdmission.admit(intent, in: admission) {
            return result(.refused(.command(refusal)))
        }
        do {
            try ledger.reserve(intent, permission: intent.permission)
        } catch {
            return result(.refused(Self.refusal(for: error)))
        }
        return result(.admitted)
    }

    /// Records the applier's completion for an admitted command.
    mutating func complete(_ command: CommandID,
                           with completion: PeerCommandCompletion) throws(PeerCommandLedgerError) {
        try ledger.complete(command, with: completion)
    }

    /// Takes the envelope's sequence slot; any break latches the session failed.
    private mutating func consume(_ sequence: PeerSequence) -> PeerCommandRefusal? {
        guard !hasFailed, let expected = expectedSequence else { return .sessionFailed }
        guard sequence == expected else {
            hasFailed = true
            return .outOfSequence(expected: expected, found: sequence)
        }
        expectedSequence = try? expected.next()
        return nil
    }

    /// Fails closed: an exact duplicate replays only under the same permission.
    private func replay(_ entry: PeerCommandLedger.Entry, intent: CommandIntent,
                        admission: AdmissionContext) -> PeerCommandOutcome {
        guard entry.intent == intent else { return .refused(.conflictingReuse) }
        guard let current = admission.permission, current.isWellFormed else {
            return .refused(.command(.rejected(.permissionDenied)))
        }
        guard current == entry.permission else { return .refused(.command(.rejected(.permissionChanged))) }
        guard let completion = entry.completion else { return .inFlight }
        return .replayed(completion)
    }

    private static func refusal(for error: PeerCommandLedgerError) -> PeerCommandRefusal {
        switch error {
        case .full(let capacity): .ledgerFull(capacity: capacity)
        case .wrongConnection: .sessionRetired(.connectionEpoch)
        case .alreadyRecorded, .unknownCommand, .alreadyCompleted: .conflictingReuse
        }
    }
}
