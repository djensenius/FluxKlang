//
//  CommandContracts.swift
//  FluxKlang
//
//  Typed command classes, connection epochs, permission fingerprints and the
//  result vocabulary. Command results align with the G-MEDIA trigger outcomes
//  (media-contract.md §6.4): a stale command is `rejectedStale`, never retried.
//

import Foundation

enum CommandTag: ContractIDTag {}
typealias CommandID = ContractID<CommandTag>

/// Every kind of command a caller can submit.
typealias CommandClass = ControlClass
enum CommandOrigin: String, Codable, Hashable, Sendable { case human, controller, assistant }

struct HostEpoch: Hashable, Sendable, Codable {
    let host: HostID
    let generation: Generation
}

/// One connection's epoch, for example a WING transport session. Compared by
/// equality only: an epoch is current when it equals the live one.
struct ConnectionEpoch: Hashable, Sendable, Codable {
    let connection: ConnectionID
    let host: HostID
    let generation: Generation
}

/// An opaque digest of the permission state a command was authorised under.
/// Callers derive it from the permission owner (#57); any change invalidates.
struct PermissionFingerprint: Hashable, Sendable, Codable {
    let rawValue: String
}

/// Why a command was rejected.
enum CommandRejection: Hashable, Sendable {
    case permissionDenied
    case permissionChanged
    case staleRevision(expected: ContractRevision, found: ContractRevision)
    case unknownParameter(ParameterID)
    case missingValue
    case invalidValue(ParameterValueError)
    case scopeDenied
    case classMismatch
    case unsupportedOperation
    case revisionChanged
}

/// The dependency that made a command stale.
enum StaleDependency: Hashable, Sendable {
    case connectionEpoch
    case hostEpoch
    case generation(GenerationKey)
}

/// The terminal G-MEDIA trigger outcomes (§2, §6.4).
enum OutcomeResult: String, Codable, Sendable, CaseIterable, BitwiseCopyable {
    case fired, firedLate, joined, cancelled, rejectedStale, dropped
}

/// Why a trigger was dropped.
enum DropReason: String, Codable, Sendable, CaseIterable, BitwiseCopyable {
    case late
    case notReady
    /// v1: a musical target outside an active loop's `[startTicks, endTicks]` (§5.5).
    case outsideLoop
    case invalidTiming
}

/// What a command produced: admission results for direct commands, or a
/// trigger outcome for scheduled ones.
enum CommandResult: Hashable, Sendable {
    case applied
    case rejected(CommandRejection)
    case stale(StaleDependency)
    case trigger(TriggerOutcome)

    /// The G-MEDIA outcome this result corresponds to, when there is one.
    var mediaOutcome: OutcomeResult? {
        switch self {
        case .applied, .rejected: nil
        case .stale: .rejectedStale
        case .trigger(let outcome): outcome.result
        }
    }
}

/// Control-plane terminal outcome; RuntimeTriggerOutcome is its fixed-size kernel counterpart.
struct TriggerOutcome: Hashable, Sendable {
    let trigger: TriggerID
    var result: OutcomeResult
    var reason: DropReason?
    var stale: StaleDependency?
    var assignedFrame: Int64?
    var frame: Int64?
    var startOffsetFrames: Int64 = 0
    /// The musical-map revision used to resolve a musical target or fallback.
    var musicalMap: Generation?

    /// Local v1 media shape (§6.3–§6.4 and outcomeRecord), not proof of
    /// freshness, readiness or the correct musical-map revision. Those need
    /// scheduler context. Command-only epoch reasons and diagnostic drop
    /// reasons are not v1 media outcomes.
    func validateMediaShape() throws(TriggerOutcomeValidationError) {
        guard startOffsetFrames >= 0 else { throw .invalidShape }
        switch result {
        case .fired, .firedLate, .joined:
            guard reason == nil, stale == nil, let assignedFrame, let frame else { throw .invalidShape }
            try validateDispatchFrames(assigned: assignedFrame, frame: frame)
        case .cancelled, .rejectedStale:
            guard reason == nil, frame == nil, startOffsetFrames == 0,
                  case .generation(let key) = stale, key.kind != .musicalMap else { throw .invalidShape }
        case .dropped:
            guard stale == nil, frame == nil, startOffsetFrames == 0,
                  reason == .late || reason == .notReady else { throw .invalidShape }
            if reason == .late, assignedFrame == nil { throw .invalidShape }
        }
    }

    private func validateDispatchFrames(assigned: Int64, frame: Int64) throws(TriggerOutcomeValidationError) {
        switch result {
        case .fired:
            guard frame == assigned, startOffsetFrames == 0 else { throw .invalidShape }
        case .firedLate:
            guard frame > assigned, startOffsetFrames == 0 else { throw .invalidShape }
        case .joined:
            guard frame > assigned, Int128(startOffsetFrames) == Int128(frame) - Int128(assigned) else {
                throw .invalidShape
            }
        default: break
        }
    }
}

enum TriggerOutcomeValidationError: Error, Equatable { case invalidShape }
