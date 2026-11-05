//
//  PeerCommandEnvelope.swift
//  FluxKlang
//
//  One session's command envelope and result (#95). The envelope sequence is
//  per session (host epoch + connection epoch) and every envelope, including a
//  retry, takes the next one. Payloads are `CommandIntent`s only: control,
//  status and telemetry, never plugin, media or file execution.
//

import Foundation

struct PeerCommandEnvelope: Hashable, Sendable {
    let sequence: PeerSequence
    let intent: CommandIntent
}

/// What the host's applier reports once an admitted command has run.
enum PeerCommandCompletion: Hashable, Sendable {
    /// Applied; `revisions` are the host's revisions afterwards.
    case applied(revisions: CommandRevisions)
    case refused(CommandResult)
}

/// Why the session layer refused an envelope.
enum PeerCommandRefusal: Hashable, Sendable {
    /// Freshness or admission, with `CommandAdmission`'s own result.
    case command(CommandResult)
    /// The live host or connection epoch is no longer this processor's session.
    case sessionRetired(StaleDependency)
    case outOfSequence(expected: PeerSequence, found: PeerSequence)
    /// An earlier envelope broke the sequence; the session must be closed.
    case sessionFailed
    /// The command ID was already used in this session for a different intent.
    case conflictingReuse
    /// The ledger is full; nothing is evicted, so the command is refused.
    case ledgerFull(capacity: Int)
}

enum PeerCommandOutcome: Hashable, Sendable {
    /// New and admitted, reserved as pending. Validated intent only: the host
    /// applier runs it and reports through `complete`.
    case admitted
    /// A duplicate of a pending command. Nothing is re-applied.
    case inFlight
    /// A duplicate of a completed command: its recorded completion, not re-applied.
    case replayed(PeerCommandCompletion)
    case refused(PeerCommandRefusal)
}

struct PeerCommandResult: Hashable, Sendable {
    let sequence: PeerSequence
    let command: CommandID
    let outcome: PeerCommandOutcome
}
