//
//  ActivationValidator.swift
//  FluxKlang
//
//  Current-context validation for every activation caller. Pure: it reads the
//  supplied context and returns a value, so a refused request emits no write.
//

import Foundation

/// Proof that a request passed validation against one context. Only the
/// validator creates it: do not add initializers in other files. It is not
/// authorization, grants no engine lease and performs no write; it is stale
/// once the live context is no longer byte-identical to `context` (equal epoch
/// and revision, identical permission bytes and capability-document encoding).
struct ValidatedActivation: Hashable, Sendable {
    let request: ActivationRequest
    let graph: GraphDocument
    /// The context the request was checked against.
    let context: ActivationContext
    /// Advisory capabilities currently absent; affected nodes degrade, they do not block.
    let missingAdvisory: Set<CapabilityID>

    fileprivate init(request: ActivationRequest, graph: GraphDocument, context: ActivationContext,
                     missingAdvisory: Set<CapabilityID>) {
        self.request = request
        self.graph = graph
        self.context = context
        self.missingAdvisory = missingAdvisory
    }
}

enum ActivationValidator {
    /// Reports only the first failure, in this order: host epoch, permission,
    /// origin, digest, base revision, graph identity, capability document
    /// staleness, candidate revision, capability document validity and bounded
    /// encoding, graph validity against advertised capabilities, graph bounded
    /// encoding, then present capabilities.
    static func validate(
        _ request: ActivationRequest, candidate: GraphDocument, in context: ActivationContext
    ) -> Result<ValidatedActivation, ActivationRejection> {
        guard request.hostEpoch == context.hostEpoch else { return .failure(.staleHostEpoch) }
        // A malformed current fingerprint grants nothing; a malformed or different
        // request fingerprint is `permissionChanged`. Fingerprints are opaque tokens,
        // so compare exact UTF-8 bytes, not Unicode canonical equivalence.
        guard let permission = context.permission, permission.isWellFormedForActivation else {
            return .failure(.permissionDenied)
        }
        guard request.permission.isWellFormedForActivation, permission.matchesExactly(request.permission) else {
            return .failure(.permissionChanged)
        }
        // The origin is caller-asserted here; being in-process or local adds nothing.
        guard request.origin == .human else { return .failure(.originCannotActivate(request.origin)) }
        guard request.digest.isValid else { return .failure(.invalidDigest) }
        guard request.baseRevision == context.activeRevision else {
            return .failure(.staleBase(expected: context.activeRevision, found: request.baseRevision))
        }
        guard candidate.id == request.graph else { return .failure(.graphMismatch) }
        let document = context.capabilities
        guard document.host == context.hostEpoch.host, document.hostEpoch == context.hostEpoch.generation else {
            return .failure(.staleCapabilities)
        }
        // Drafts never bump the revision; only an acknowledged activation does.
        guard candidate.revision == request.baseRevision else {
            return .failure(.staleBase(expected: context.activeRevision, found: candidate.revision))
        }
        return assess(candidate, capabilities: document).map {
            ValidatedActivation(request: request, graph: candidate, context: context, missingAdvisory: $0)
        }
    }

    /// Document validity and bounded encoding, graph validity against every
    /// capability the host document advertises and its bounded encoding, then
    /// live presence. Returns the missing advisory capabilities.
    private static func assess(
        _ candidate: GraphDocument, capabilities document: DeviceCapabilityDocument
    ) -> Result<Set<CapabilityID>, ActivationRejection> {
        // `encoded()` enforces the 4 MiB byte limit that `validate()` does not; any failure is invalid.
        guard (try? document.validate()) != nil, (try? document.encoded()) != nil else {
            return .failure(.invalidCapabilities)
        }
        let advertised = Set(document.devices.flatMap(\.capabilities))
        do {
            try candidate.validateForPreparation(supportedCapabilities: advertised)
        } catch {
            return .failure(.invalidGraph(error))
        }
        do {
            _ = try candidate.encoded()
        } catch let error as ProjectGraphLimitError {
            return .failure(.invalidGraph(.bounds(error)))
        } catch {
            return .failure(.unencodableGraph)
        }
        // Required on any node wins over advisory on another.
        let required = Set(candidate.nodes.flatMap(\.requiredCapabilities))
        let advisory = Set(candidate.nodes.flatMap(\.advisoryCapabilities)).subtracting(required)
        let requirements = required.sorted().map { CapabilityRequirement(capability: $0, level: .required) }
            + advisory.sorted().map { CapabilityRequirement(capability: $0, level: .advisory) }
        guard let assessment = try? document.assess(requirements) else { return .failure(.invalidCapabilities) }
        guard assessment.requirementsSatisfied else {
            return .failure(.missingCapabilities(assessment.missingRequired))
        }
        return .success(assessment.missingAdvisory)
    }
}

/// The one permission check every activation step shares.
extension PermissionFingerprint {
    /// Same bounds as `CommandIntentFields.validate`: 1…256 UTF-8 bytes.
    var isWellFormedForActivation: Bool { (1...256).contains(rawValue.utf8.count) }

    /// Exact UTF-8 byte equality. Fingerprints are opaque tokens, so Unicode
    /// canonical equivalence (`String ==`) is not a match.
    func matchesExactly(_ other: PermissionFingerprint) -> Bool {
        rawValue.utf8.elementsEqual(other.rawValue.utf8)
    }
}
