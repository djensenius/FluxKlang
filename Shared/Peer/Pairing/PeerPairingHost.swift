//
//  PeerPairingHost.swift
//  FluxKlang
//
//  The host side of one pairing attempt at a time (#94 P1). Only the host
//  approves, and only with an explicit role and grants; nothing is ever
//  approved by default. Deny, Escape and the decision deadline all deny. Every
//  finished attempt is terminal: further input is refused, and a new attempt
//  needs a new request and a fresh host nonce. Reused nonces are refused.
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

enum PeerPairingPhase: Hashable, Sendable {
    case idle
    case awaitingReveal
    /// The prompt is up with this code; Deny and Allow have equal weight and no default.
    case awaitingDecision(PeerConfirmationCode)
    case finished(PeerPairingOutcome)
}

/// The host's answer to the prompt. Allow carries the role explicitly inside its grants.
enum PeerPairingDecision: Hashable, Sendable {
    case allow(PeerGrantSet)
    case deny
    /// Escape dismisses the prompt, which denies.
    case escape
}

/// Misuse refused without changing the attempt.
enum PeerPairingError: Error, Hashable, Sendable {
    case busy
    case identityMismatch
    case nonceReplay
    case unexpectedStep
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
        let hostNonce: PeerNonce
        let deadline: ContinuousClock.Instant
    }

    let identity: PeerIdentityFingerprint
    private(set) var phase = PeerPairingPhase.idle
    private var pending: Pending?
    private var nonceOrder: [PeerNonce] = []
    private var seenNonces: Set<PeerNonce> = []

    init(identity: PeerIdentityFingerprint) {
        self.identity = identity
    }

    /// Starts an attempt for `request`, which must come from `transportIdentity`.
    mutating func begin(_ request: PeerPairingRequest, transportIdentity: PeerIdentityFingerprint,
                        hostNonce: PeerNonce, now: ContinuousClock.Instant,
                        trust: PeerTrustStore) throws(PeerPairingError) {
        tick(now: now)
        guard pending == nil else { throw .busy }
        guard request.identity == transportIdentity, request.identity != identity else { throw .identityMismatch }
        do {
            try trust.checkPairable(request.identity)
        } catch { throw .trust(error) }
        guard !seenNonces.contains(hostNonce) else { throw .nonceReplay }
        remember(hostNonce)
        pending = Pending(request: request, hostNonce: hostNonce, deadline: now + Self.decisionWindow)
        phase = .awaitingReveal
    }

    /// Accepts the peer's nonce reveal and, if it opens the commitment, shows the code.
    @discardableResult
    mutating func reveal(_ peerNonce: PeerNonce, now: ContinuousClock.Instant) throws(PeerPairingError)
        -> PeerPairingPhase {
        tick(now: now)
        guard phase == .awaitingReveal, let pending else { throw .unexpectedStep }
        guard !seenNonces.contains(peerNonce) else { return finish(.denied(.nonceReplay)) }
        remember(peerNonce)
        guard PeerPairingCommitment(identity: pending.request.identity, nonce: peerNonce)
                == pending.request.commitment else { return finish(.denied(.commitmentMismatch)) }
        let transcript = PeerPairingTranscript(host: identity, request: pending.request,
                                               hostNonce: pending.hostNonce, peerNonce: peerNonce)
        phase = .awaitingDecision(PeerConfirmationCode(transcript))
        return phase
    }

    /// Applies the host's decision. Only `.allow` trusts, with exactly its role and grants.
    mutating func decide(_ decision: PeerPairingDecision, now: ContinuousClock.Instant,
                         trust: inout PeerTrustStore) throws(PeerPairingError) -> PeerPairingOutcome {
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
