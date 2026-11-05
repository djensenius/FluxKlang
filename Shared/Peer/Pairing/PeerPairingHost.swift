//
//  PeerPairingHost.swift
//  FluxKlang
//
//  The host side of one pairing attempt at a time (#94 P1). Only the host
//  approves, and only with an explicit role and grants; nothing is ever
//  approved by default. Deny, Escape and the decision deadline all deny. Every
//  finished attempt is terminal: further input is refused, and a new attempt
//  needs a new request and a fresh host nonce. Reused nonces are refused.
//  Every attempt has a host-issued, strictly increasing attempt ID, and every
//  decision must name it, so a prompt left over from an earlier attempt can
//  never decide a later one.
//
//  Attempt IDs are per `PeerPairingHost` instance: a second instance would
//  issue the same IDs again. Integration must keep exactly one
//  `PeerPairingHost` per host process for that process's lifetime.
//

/// Why an attempt ended without trust.
enum PeerPairingDenial: Hashable, Sendable {
    case denied
    case escaped
    case timedOut
    case commitmentMismatch
    case nonceReplay
    /// The store refused at approval time, for example because it filled up meanwhile.
    case trustRefused(PeerTrustError)
}

enum PeerPairingOutcome: Hashable, Sendable {
    case approved(PeerTrustRecord)
    case denied(PeerPairingDenial)
}

/// Host-issued attempt number from a counter that only increases for the
/// host's lifetime (never reset by a timeout, Deny or Escape). It is not
/// derived from the code or the nonces.
struct PeerPairingAttemptID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let value: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    var description: String { "attempt-\(value)" }
}

/// What the host's prompt binds to: decisions must carry `attempt`.
struct PeerPairingPrompt: Hashable, Sendable {
    let attempt: PeerPairingAttemptID
    let code: PeerConfirmationCode
}

enum PeerPairingPhase: Hashable, Sendable {
    case idle
    case awaitingReveal(PeerPairingAttemptID)
    /// The prompt is up; Deny and Allow have equal weight and no default.
    case awaitingDecision(PeerPairingPrompt)
    case finished(PeerPairingOutcome)
}

/// The host's answer to the prompt. Allow carries the role explicitly inside its grants.
enum PeerPairingDecision: Hashable, Sendable {
    case allow(PeerGrantSet)
    case deny
    /// Escape (cancel) dismisses the prompt, which denies.
    case escape
}

/// Misuse refused without changing the attempt.
enum PeerPairingError: Error, Hashable, Sendable {
    case busy
    case identityMismatch
    case nonceReplay
    case unexpectedStep
    /// The decision named an attempt other than the one awaiting a decision.
    case staleAttempt
    /// Every attempt ID has been issued; the host refuses new attempts rather than wrap.
    case attemptsExhausted
    case trust(PeerTrustError)
}

struct PeerPairingHost: Sendable {
    static let decisionWindow = Duration.seconds(60)
    /// Remembered nonces, host and peer, in arrival order. The most recent 256
    /// are refused on reuse; remembering a 257th forgets the oldest. The fresh
    /// host nonce in every transcript is the primary replay defence; this
    /// memory additionally refuses recent reuse.
    static let nonceMemory = 256

    private struct Pending: Sendable {
        let request: PeerPairingRequest
        let attempt: PeerPairingAttemptID
        let hostNonce: PeerNonce
        let deadline: ContinuousClock.Instant
    }

    let identity: PeerIdentityFingerprint
    private(set) var phase = PeerPairingPhase.idle
    private var pending: Pending?
    /// The last issued attempt ID; only ever increases.
    private var lastAttempt = PeerPairingAttemptID(value: 0)
    private var nonceOrder: [PeerNonce] = []
    private var seenNonces: Set<PeerNonce> = []

    /// The production initializer: the attempt counter starts at zero.
    init(identity: PeerIdentityFingerprint) {
        self.init(identity: identity, lastAttempt: PeerPairingAttemptID(value: 0))
    }

    /// Test seam only, so tests can reach counter exhaustion. Production code
    /// must never call it: restarting the counter would reissue attempt IDs.
    init(identity: PeerIdentityFingerprint, testingLastIssuedAttempt: PeerPairingAttemptID) {
        self.init(identity: identity, lastAttempt: testingLastIssuedAttempt)
    }

    private init(identity: PeerIdentityFingerprint, lastAttempt: PeerPairingAttemptID) {
        self.identity = identity
        self.lastAttempt = lastAttempt
    }

    /// Starts an attempt for `request`, which must come from `transportIdentity`,
    /// and returns its new attempt ID.
    @discardableResult
    mutating func begin(_ request: PeerPairingRequest, transportIdentity: PeerIdentityFingerprint,
                        hostNonce: PeerNonce, now: ContinuousClock.Instant,
                        trust: PeerTrustStore) throws(PeerPairingError) -> PeerPairingAttemptID {
        tick(now: now)
        guard pending == nil else { throw .busy }
        guard request.identity == transportIdentity, request.identity != identity else { throw .identityMismatch }
        do {
            try trust.checkPairable(request.identity)
        } catch { throw .trust(error) }
        guard !seenNonces.contains(hostNonce) else { throw .nonceReplay }
        guard lastAttempt.value < UInt64.max else { throw .attemptsExhausted }
        remember(hostNonce)
        let attempt = PeerPairingAttemptID(value: lastAttempt.value + 1)
        lastAttempt = attempt
        pending = Pending(request: request, attempt: attempt, hostNonce: hostNonce,
                          deadline: now + Self.decisionWindow)
        phase = .awaitingReveal(attempt)
        return attempt
    }

    /// Accepts the peer's nonce reveal and, if it opens the commitment, shows the code.
    @discardableResult
    mutating func reveal(_ peerNonce: PeerNonce, now: ContinuousClock.Instant) throws(PeerPairingError)
        -> PeerPairingPhase {
        tick(now: now)
        guard let pending, phase == .awaitingReveal(pending.attempt) else { throw .unexpectedStep }
        guard !seenNonces.contains(peerNonce) else { return finish(.denied(.nonceReplay)) }
        remember(peerNonce)
        guard PeerPairingCommitment(identity: pending.request.identity, nonce: peerNonce)
                == pending.request.commitment else { return finish(.denied(.commitmentMismatch)) }
        let transcript = PeerPairingTranscript(host: identity, request: pending.request,
                                               hostNonce: pending.hostNonce, peerNonce: peerNonce)
        phase = .awaitingDecision(PeerPairingPrompt(attempt: pending.attempt, code: PeerConfirmationCode(transcript)))
        return phase
    }

    /// Applies the host's decision for `attempt`. Only `.allow` trusts, with
    /// exactly its role and grants. A decision for any other attempt is
    /// refused with `.staleAttempt` and changes nothing at all.
    mutating func decide(_ decision: PeerPairingDecision, for attempt: PeerPairingAttemptID,
                         now: ContinuousClock.Instant,
                         trust: inout PeerTrustStore) throws(PeerPairingError) -> PeerPairingOutcome {
        // Checked before `tick`: a stale call changes nothing, not even a due timeout.
        // Only the latest issued attempt can be pending, so one comparison covers every older or unknown ID.
        guard attempt == lastAttempt else { throw .staleAttempt }
        tick(now: now)
        guard case .awaitingDecision = phase, let pending else { throw .unexpectedStep }
        let outcome: PeerPairingOutcome
        switch decision {
        case .deny: outcome = .denied(.denied)
        case .escape: outcome = .denied(.escaped)
        case .allow(let grants):
            do {
                outcome = .approved(try trust.pair(pending.request.identity, label: pending.request.label,
                                                   grants: grants,
                                                   protocolFloor: pending.request.session.protocolVersion))
            } catch { outcome = .denied(.trustRefused(error)) }
        }
        finish(outcome)
        return outcome
    }

    /// Denies a pending attempt whose deadline has passed.
    @discardableResult
    mutating func tick(now: ContinuousClock.Instant) -> PeerPairingPhase {
        if let pending, now >= pending.deadline { return finish(.denied(.timedOut)) }
        return phase
    }

    @discardableResult
    private mutating func finish(_ outcome: PeerPairingOutcome) -> PeerPairingPhase {
        pending = nil
        phase = .finished(outcome)
        return phase
    }

    private mutating func remember(_ nonce: PeerNonce) {
        seenNonces.insert(nonce)
        nonceOrder.append(nonce)
        if nonceOrder.count > Self.nonceMemory { seenNonces.remove(nonceOrder.removeFirst()) }
    }
}
