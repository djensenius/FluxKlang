//
//  UndoRebindRefusal.swift
//  FluxKlang
//
//  Why an undo-session value was not built or a rebind was refused.
//

/// Every typed refusal of the undo-session types and of the rebind policy. The order of the policy's checks is
/// documented on `UndoSessionRebindPolicy`.
enum UndoRebindRefusal: Error, Equatable, Sendable {
    /// The digest is not `CheckpointRecord.digestByteCount` bytes; the payload is its length.
    case invalidDigestLength(Int)
    /// The byte count is outside 0...`CheckpointLimits.hardMaximumRecordBytes`.
    case invalidByteCount(Int)
    /// A stack count is negative or above the depth, or the two counts together exceed the depth.
    case sessionInvalid
    /// The reason is not 1...64 UTF-8 bytes; the payload is its `utf8.count`.
    case reasonBytes(Int)
    case draftMismatch(expected: DraftID, found: DraftID)
    case graphMismatch(expected: GraphID, found: GraphID)
    case revisionMismatch(expected: ContractRevision, found: ContractRevision)
    /// Same revision, other content; the payload is that revision.
    case contentMismatch(ContractRevision)
    case preRestoreMissing
    /// The supplied record is not a `preRestore` record; the payload is its reason.
    case preRestoreWrongReason(CheckpointReason)
    case preRestoreRevisionStale(expected: ContractRevision, found: ContractRevision)
    case preRestoreContentStale
    case targetGraphMismatch(expected: GraphID, found: GraphID)
    /// The target revision is not greater than the session revision.
    case targetNotNewer(session: ContractRevision, target: ContractRevision)
    /// The binding matches, but the depth, a stack count, the unsaved flag or the mutation generation differs from
    /// the session the ticket was issued for.
    case staleTicket
}
