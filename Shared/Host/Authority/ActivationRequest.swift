//
//  ActivationRequest.swift
//  FluxKlang
//
//  What a caller asks to activate and the host context it is checked against.
//  Values only: nothing here grants an engine lease, authorizes or writes.
//

import Foundation

/// An opaque, caller-supplied digest of the reviewed activation. #62 does not
/// compute it yet; validation only bounds it to 1…256 UTF-8 bytes.
struct ActivationDigest: Hashable, Sendable, Codable {
    static let maximumBytes = 256
    let rawValue: String

    var isValid: Bool { (1...Self.maximumBytes).contains(rawValue.utf8.count) }
}

/// A direct request to activate a draft graph over the running revision.
/// `origin` is the command origin; process locality carries no privilege.
struct ActivationRequest: Hashable, Sendable {
    let draft: DraftID
    let graph: GraphID
    let baseRevision: ContractRevision
    let hostEpoch: HostEpoch
    let permission: PermissionFingerprint
    let digest: ActivationDigest
    let origin: CommandOrigin
}

/// The host's current state, supplied by the caller that owns it.
struct ActivationContext: Hashable, Sendable {
    let hostEpoch: HostEpoch
    /// The running graph revision a request must be based on.
    let activeRevision: ContractRevision
    /// `nil` when no permission is currently granted.
    let permission: PermissionFingerprint?
    let capabilities: DeviceCapabilityDocument
}

/// Why an activation request was refused. Exactly one reason is reported:
/// the first failing check. Later slices add lease and authorization cases.
enum ActivationRejection: Error, Hashable, Sendable {
    case staleHostEpoch
    case permissionDenied
    case permissionChanged
    case originCannotActivate(CommandOrigin)
    case invalidDigest
    case staleBase(expected: ContractRevision, found: ContractRevision)
    case graphMismatch
    case invalidGraph(GraphValidationError)
    /// The graph cannot be encoded (for example a non-finite extension number).
    case unencodableGraph
    /// The capability document failed validation or bounded encoding.
    case invalidCapabilities
    case missingCapabilities(Set<CapabilityID>)
    case staleCapabilities
}
