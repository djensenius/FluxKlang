//
//  PeerPairingInitiator.swift
//  FluxKlang
//
//  The controller side of one pairing attempt at a time (#94 P2), the mirror of
//  `PeerPairingHost`: it commits to a fresh nonce, learns the host's nonce,
//  reveals its own on request, derives the same six-digit code from the same
//  transcript and reports user-facing status. No transport, no wire frame, no
//  clock read (callers pass `ContinuousClock.Instant` values), no persistence,
//  no `Codable`. The initiator never builds grants and never touches a trust
//  store: the host alone decides what a peer may do.
//
//  Every step first resolves an expired deadline: `now >= deadline` ends an
//  attempt that is in flight as `.timedOut`, drops the attempt record (and its
//  nonce) and throws `.timedOut`, before any other check. Every terminal attempt
//  drops that record; no test can observe the drop itself, because the status
//  already refuses a reveal.
//  Apart from that timeout and a replayed host nonce (which ends the attempt as
//  `denied(.nonceReplay)`), a refused call changes nothing.
//
//  Limits: "reveal once" holds per VALUE, because a caller can copy this struct
//  before the call and each copy reveals once. Replay protection lives in the
//  host's nonce memory. Instant arithmetic near the clock's extremes is not
//  exercised, as in the host.
//

/// Misuse or protocol failure refused by the initiator or the payload.
enum PeerInitiatorError: Error, Hashable, Sendable {
    /// An attempt is in flight; finish it (or `tick` past its deadline) first.
    case busy
    /// Our identity equals the host's.
    case sameIdentity
    case invalidLabel
    /// The negotiated protocol version is 0.
    case protocolVersionInvalid
    /// The nonce was seen recently (ours or the host's).
    case nonceReplay
    case unexpectedStep
    /// The decision deadline passed; the attempt is now `.timedOut`.
    case timedOut
    /// The host approved although our nonce was never handed out.
    case nonceNotRevealed
}

/// Who asks whom, over which session. Plain data; `startAttempt` validates every field.
struct PeerPairingAttemptSpec: Hashable, Sendable {
    let identity: PeerIdentityFingerprint
    let hostIdentity: PeerIdentityFingerprint
    let label: String
    let role: PeerRole
    let session: PeerNegotiatedSession

    /// Labels are compared by their UTF-8 bytes, as the label rule measures them.
    static func == (lhs: PeerPairingAttemptSpec, rhs: PeerPairingAttemptSpec) -> Bool {
        lhs.identity == rhs.identity && lhs.hostIdentity == rhs.hostIdentity && lhs.role == rhs.role
            && lhs.session == rhs.session && lhs.label.utf8.elementsEqual(rhs.label.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
        hasher.combine(hostIdentity)
        hasher.combine(role)
        hasher.combine(session)
        hasher.combine(label.utf8.count)
        for byte in label.utf8 { hasher.combine(byte) }
    }
}

struct PeerPairingInitiator: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                             CustomReflectable {
    static let decisionWindow = PeerPairingHost.decisionWindow
    /// Remembered nonces, ours and the host's, in arrival order; remembering a 257th forgets the oldest.
    static let nonceMemory = PeerPairingHost.nonceMemory

    private struct Attempt: Hashable, Sendable {
        let hostIdentity: PeerIdentityFingerprint
        let request: PeerPairingRequest
        let nonce: PeerNonce
        let deadline: ContinuousClock.Instant
        var nonceRevealed = false

        /// The request label is compared by its UTF-8 bytes in addition to the request's own equality.
        static func == (lhs: Attempt, rhs: Attempt) -> Bool {
            lhs.hostIdentity == rhs.hostIdentity && lhs.nonce == rhs.nonce && lhs.deadline == rhs.deadline
                && lhs.nonceRevealed == rhs.nonceRevealed && lhs.request == rhs.request
                && lhs.request.label.utf8.elementsEqual(rhs.request.label.utf8)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(hostIdentity)
            hasher.combine(nonce)
            hasher.combine(deadline)
            hasher.combine(nonceRevealed)
            hasher.combine(request)
        }
    }

    private(set) var status = PeerPairingStatus.idle
    private var attempt: Attempt?
    private var nonceOrder: [PeerNonce] = []
    private var seenNonces: Set<PeerNonce> = []

    init() {}

    /// The phase name only: the six-digit code, the nonce and the attempt are not printed, so logging an
    /// initiator does not log the code.
    var description: String { "PeerPairingInitiator(\(phaseName))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["phase": phaseName]) }

    /// A fresh initiator and the request of its first attempt.
    static func begin(_ spec: PeerPairingAttemptSpec, nonce: PeerNonce, now: ContinuousClock.Instant)
        throws(PeerInitiatorError) -> (PeerPairingInitiator, PeerPairingRequest) {
        var initiator = PeerPairingInitiator()
        let request = try initiator.startAttempt(spec, nonce: nonce, now: now)
        return (initiator, request)
    }

    /// Commits to `nonce` and returns the request to send. Refuses, in this order and changing nothing:
    /// `.busy`, `.sameIdentity`, `.invalidLabel`, `.protocolVersionInvalid`, `.nonceReplay`.
    /// Allowed only while idle or after a terminal attempt; the nonce memory carries over.
    mutating func startAttempt(_ spec: PeerPairingAttemptSpec, nonce: PeerNonce,
                               now: ContinuousClock.Instant) throws(PeerInitiatorError) -> PeerPairingRequest {
        guard status == .idle || status.isTerminal else { throw .busy }
        guard spec.identity != spec.hostIdentity else { throw .sameIdentity }
        guard PeerPairingLabelRule.isValid(spec.label) else { throw .invalidLabel }
        guard spec.session.protocolVersion >= 1 else { throw .protocolVersionInvalid }
        guard !seenNonces.contains(nonce) else { throw .nonceReplay }
        remember(nonce)
        let request = PeerPairingRequest(identity: spec.identity, label: spec.label, requestedRole: spec.role,
                                         commitment: PeerPairingCommitment(identity: spec.identity, nonce: nonce),
                                         session: spec.session)
        attempt = Attempt(hostIdentity: spec.hostIdentity, request: request, nonce: nonce,
                          deadline: now + Self.decisionWindow)
        status = .committed
        return request
    }

    /// The request has been handed to the transport.
    mutating func requestSent(now: ContinuousClock.Instant) throws(PeerInitiatorError) {
        try resolveDeadline(now: now)
        guard status == .committed else { throw .unexpectedStep }
        status = .awaitingHostNonce
    }

    /// Takes the host's nonce and returns the code to show. A nonce in the memory (our own included) ends
    /// the attempt as `denied(.nonceReplay)` and throws `.nonceReplay`.
    mutating func receiveHostNonce(_ hostNonce: PeerNonce,
                                   now: ContinuousClock.Instant) throws(PeerInitiatorError) -> PeerConfirmationCode {
        try resolveDeadline(now: now)
        guard status == .awaitingHostNonce, let current = attempt else { throw .unexpectedStep }
        guard !seenNonces.contains(hostNonce) else {
            finish(.denied(.nonceReplay))
            throw .nonceReplay
        }
        remember(hostNonce)
        let transcript = PeerPairingTranscript(host: current.hostIdentity, request: current.request,
                                               hostNonce: hostNonce, peerNonce: current.nonce)
        let code = PeerConfirmationCode(transcript)
        status = .showingCode(code)
        return code
    }

    /// Our nonce for the host's reveal step. It can be returned only while the code is shown (`showingCode`,
    /// before the person has answered) or the host's decision is awaited, never after the deadline, a denial
    /// or a pairing, and at most once per value: a copy of the value made before the call reveals again.
    mutating func revealToSend(now: ContinuousClock.Instant) -> PeerNonce? {
        tick(now: now)
        guard var current = attempt, !current.nonceRevealed, canReveal else { return nil }
        current.nonceRevealed = true
        attempt = current
        return current.nonce
    }

    /// The person's answer. `codesMatch: false` denies, and the nonce cannot be revealed afterwards (a nonce
    /// already revealed in `showingCode` stays revealed to the host).
    mutating func userConfirmed(codesMatch: Bool, now: ContinuousClock.Instant) throws(PeerInitiatorError) {
        try resolveDeadline(now: now)
        guard case .showingCode = status else { throw .unexpectedStep }
        if codesMatch {
            status = .awaitingHostDecision
        } else {
            finish(.denied(.codesDidNotMatch))
        }
    }

    /// The host's answer. A denial ends the attempt as `denied(.hostDenied)` while the host's prompt can be up
    /// (`awaitingHostNonce`, `showingCode`, `awaitingHostDecision`). An approval is accepted only in
    /// `awaitingHostDecision`, and only after our nonce was revealed (`.nonceNotRevealed` otherwise); in the two
    /// earlier phases it throws `.unexpectedStep` and changes nothing.
    mutating func hostOutcome(approved: Bool, now: ContinuousClock.Instant) throws(PeerInitiatorError) {
        try resolveDeadline(now: now)
        guard hostCanAnswer, let current = attempt else { throw .unexpectedStep }
        guard approved else {
            finish(.denied(.hostDenied))
            return
        }
        guard status == .awaitingHostDecision else { throw .unexpectedStep }
        guard current.nonceRevealed else { throw .nonceNotRevealed }
        finish(.paired)
    }

    /// Times out an attempt in flight whose deadline has passed.
    @discardableResult
    mutating func tick(now: ContinuousClock.Instant) -> PeerPairingStatus {
        if let attempt, now >= attempt.deadline { finish(.timedOut) }
        return status
    }

    private var hostCanAnswer: Bool {
        switch status {
        case .awaitingHostNonce, .showingCode, .awaitingHostDecision: true
        case .idle, .committed, .paired, .denied, .timedOut: false
        }
    }

    private var phaseName: String {
        switch status {
        case .idle: "idle"
        case .committed: "committed"
        case .awaitingHostNonce: "awaitingHostNonce"
        case .showingCode: "showingCode"
        case .awaitingHostDecision: "awaitingHostDecision"
        case .paired: "paired"
        case .denied(let reason): "denied(\(reason))"
        case .timedOut: "timedOut"
        }
    }

    private var canReveal: Bool {
        switch status {
        case .showingCode, .awaitingHostDecision: true
        case .idle, .committed, .awaitingHostNonce, .paired, .denied, .timedOut: false
        }
    }

    private mutating func resolveDeadline(now: ContinuousClock.Instant) throws(PeerInitiatorError) {
        guard let attempt, now >= attempt.deadline else { return }
        finish(.timedOut)
        throw .timedOut
    }

    private mutating func finish(_ terminal: PeerPairingStatus) {
        attempt = nil
        status = terminal
    }

    private mutating func remember(_ nonce: PeerNonce) {
        seenNonces.insert(nonce)
        nonceOrder.append(nonce)
        if nonceOrder.count > Self.nonceMemory { seenNonces.remove(nonceOrder.removeFirst()) }
    }
}
