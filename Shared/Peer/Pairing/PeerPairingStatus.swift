//
//  PeerPairingStatus.swift
//  FluxKlang
//
//  What the controller shows while it pairs (#94 P2): a plain value, not
//  `Codable`, holding only the six-digit confirmation code (a human check, never
//  an identity and never a nonce). The pairing protocol is still subject to the
//  G-PAIR design review.
//

/// Why an attempt ended without trust, from the controller's side.
enum PeerPairingDeniedReason: Hashable, Sendable {
    /// The person said the two codes differ.
    case codesDidNotMatch
    /// The host answered Deny, Escape or its own deadline.
    case hostDenied
    /// The host's nonce was our own or had been seen recently.
    case nonceReplay
}

/// The initiator's user-facing state. `paired`, `denied` and `timedOut` are terminal.
enum PeerPairingStatus: Hashable, Sendable {
    case idle
    /// The request exists but is not yet known to have been sent.
    case committed
    case awaitingHostNonce
    case showingCode(PeerConfirmationCode)
    case awaitingHostDecision
    case paired
    case denied(PeerPairingDeniedReason)
    case timedOut

    var isTerminal: Bool {
        switch self {
        case .paired, .denied, .timedOut: true
        case .idle, .committed, .awaitingHostNonce, .showingCode, .awaitingHostDecision: false
        }
    }

    /// The code the person must compare, only while it is shown.
    var code: PeerConfirmationCode? {
        guard case .showingCode(let code) = self else { return nil }
        return code
    }
}
