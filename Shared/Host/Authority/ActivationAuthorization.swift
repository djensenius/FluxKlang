//
//  ActivationAuthorization.swift
//  FluxKlang
//
//  Who may authorize committing a reviewed activation, and the single-use
//  proof they receive. Only a `.human` origin from the trusted gesture path,
//  holding the current permission, can obtain one; process locality and the
//  request's own (caller-asserted) origin add nothing.
//

/// Consent to commit one prepared activation. Only `ActivationAuthorizer`
/// creates one: do not add initializers in other files. It is bound to the
/// prepared request's draft, base revision, host epoch and digest and to a
/// nonce, and every issue has its own identity, so no other code path can
/// produce an equal value even with the same fields and nonce.
struct ActivationAuthorization: Hashable, Sendable {
    fileprivate final class Identity: Sendable {}
    fileprivate let instance: Identity
    let draft: DraftID
    let baseRevision: ContractRevision
    let hostEpoch: HostEpoch
    let digest: ActivationDigest
    /// Issued from a bounded counter; compared for equality only.
    let nonce: Generation

    fileprivate init(request: ActivationRequest, nonce: Generation) {
        instance = Identity()
        draft = request.draft
        baseRevision = request.baseRevision
        hostEpoch = request.hostEpoch
        digest = request.digest
        self.nonce = nonce
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.instance === rhs.instance && lhs.nonce == rhs.nonce && lhs.draft == rhs.draft
            && lhs.baseRevision == rhs.baseRevision && lhs.hostEpoch == rhs.hostEpoch && lhs.digest == rhs.digest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(instance))
        hasher.combine(nonce)
    }
}

/// Why an authorization does not cover the prepared activation. Reported in
/// this order: nothing outstanding, draft, base revision, host epoch, digest,
/// then not the outstanding authorization (replaced, used or issued elsewhere).
enum AuthorizationDefect: Hashable, Sendable {
    case noneOutstanding
    case draft
    case baseRevision
    case hostEpoch
    case digest
    case notOutstanding
}

/// Issues authorizations from a deterministic, monotonic nonce. At most one is
/// outstanding: issuing another replaces it, and consuming or revoking it
/// leaves none. Sendable does not provide synchronization; the owner serializes access.
struct ActivationAuthorizer: Hashable, Sendable {
    /// The last issued nonce; it never repeats.
    private(set) var lastNonce: Generation?
    private(set) var outstanding: ActivationAuthorization?

    /// For diagnostics and test continuity only (for example exercising overflow).
    /// nil starts at nonce 1.
    init(resumingAfter lastNonce: Generation? = nil) {
        self.lastNonce = lastNonce
    }

    /// `origin` must come from the trusted gesture path, never from the request.
    /// `permission` is the live permission (nil when none is granted); a missing
    /// or malformed one is `permissionDenied`, one whose bytes differ from the
    /// request's is `permissionChanged`. Checks, first failure wins: gesture
    /// origin, agreement with the request's origin, permission, then nonce
    /// overflow. A refusal changes nothing.
    mutating func issue(
        for validated: ValidatedActivation, origin: CommandOrigin, permission: PermissionFingerprint?
    ) -> Result<ActivationAuthorization, ActivationRefusal> {
        guard origin == .human else { return .failure(.rejected(.originCannotActivate(origin))) }
        // The validator only passes `.human` requests; a disagreement is still refused.
        guard validated.request.origin == origin else {
            return .failure(.rejected(.originCannotActivate(validated.request.origin)))
        }
        guard let permission, permission.isWellFormedForActivation else {
            return .failure(.rejected(.permissionDenied))
        }
        guard permission.matchesExactly(validated.request.permission) else {
            return .failure(.rejected(.permissionChanged))
        }
        let nonce: Generation
        if let lastNonce {
            do { nonce = try lastNonce.next() } catch { return .failure(.overflow) }
        } else {
            nonce = .initial
        }
        let authorization = ActivationAuthorization(request: validated.request, nonce: nonce)
        lastNonce = nonce
        outstanding = authorization
        return .success(authorization)
    }

    /// nil when `authorization` is the outstanding one for `request`.
    func defect(of authorization: ActivationAuthorization, for request: ActivationRequest) -> AuthorizationDefect? {
        guard let outstanding else { return .noneOutstanding }
        guard authorization.draft == request.draft else { return .draft }
        guard authorization.baseRevision == request.baseRevision else { return .baseRevision }
        guard authorization.hostEpoch == request.hostEpoch else { return .hostEpoch }
        guard authorization.digest == request.digest else { return .digest }
        guard authorization == outstanding else { return .notOutstanding }
        return nil
    }

    /// Ends the outstanding authorization, used or not.
    mutating func revoke() {
        outstanding = nil
    }
}
