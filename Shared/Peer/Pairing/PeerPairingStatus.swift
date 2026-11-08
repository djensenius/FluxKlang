//
//  PeerPairingStatus.swift
//  FluxKlang
//
//  What the controller shows while it pairs (#94 P2): plain values, not
//  `Codable`, holding only the six-digit confirmation code (a human check, never
//  an identity and never a nonce) and an attempt number. The pairing protocol is
//  still subject to the G-PAIR design review.
//

/// Initiator-issued attempt number, from a counter that only increases for the
/// life of one initiator value (never reset by a timeout, a denial, a pairing or a
/// refused start). It is not derived from the code or the nonces, and it is not a
/// secret or a capability: it only lets the person's answer name the prompt it
/// answers. A distinct type from the host's `PeerPairingAttemptID`, so a host
/// number cannot be passed to the initiator.
struct PeerInitiatorAttemptID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let value: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    var description: String { "attempt-\(value)" }
}

/// What the controller's prompt binds to: the person's answer must carry `attempt`.
struct PeerInitiatorPrompt: Hashable, Sendable {
    let attempt: PeerInitiatorAttemptID
    let code: PeerConfirmationCode
}

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
    case showingCode(PeerInitiatorPrompt)
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

    /// The prompt the person must answer, only while it is shown.
    var prompt: PeerInitiatorPrompt? {
        guard case .showingCode(let prompt) = self else { return nil }
        return prompt
    }

    /// The code the person must compare, only while it is shown.
    var code: PeerConfirmationCode? { prompt?.code }
}
