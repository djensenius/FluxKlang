//
//  PeerPairingTranscript.swift
//  FluxKlang
//
//  Numeric-comparison pairing material (#94 P1), modelled on commit-then-reveal
//  short authentication strings: the peer commits to its nonce and identity
//  before it sees the host's fresh nonce, so a man in the middle cannot search
//  for a colliding code. The 6-digit confirmation code is derived from the full
//  transcript hash and is only a human check that both screens saw the same
//  transcript. It is not a fingerprint, never an identity, and never stored.
//  The protocol is pending the G-PAIR design review.
//

/// The peer's commitment, sent before the host nonce:
/// `PeerTrustDigest.sha256(domain: "fluxklang.peer.pair.commit.v1", [identity (32 B), nonce (32 B)])`.
struct PeerPairingCommitment: Hashable, Sendable {
    static let byteCount = 32

    let bytes: [UInt8]

    init?(_ bytes: some Sequence<UInt8>) {
        let bytes = Array(bytes)
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    init(identity: PeerIdentityFingerprint, nonce: PeerNonce) {
        bytes = PeerTrustDigest.sha256(domain: "fluxklang.peer.pair.commit.v1", [identity.bytes, nonce.bytes])
    }
}

/// What the peer asks for. `identity` must equal the transport's identity.
struct PeerPairingRequest: Hashable, Sendable {
    let identity: PeerIdentityFingerprint
    let label: String
    /// Shown to the host; never applied without the host's explicit choice.
    let requestedRole: PeerRole
    let commitment: PeerPairingCommitment
    /// The session pairing runs over; its version becomes the record's floor.
    let session: PeerNegotiatedSession
}

/// The hash of everything both sides agreed during one pairing attempt:
/// `PeerTrustDigest.sha256(domain: "fluxklang.peer.pair.transcript.v1", parts)` where `parts` are, in order,
/// host identity (32 B), peer identity (32 B), commitment (32 B), host nonce (32 B), peer nonce (32 B),
/// requested role raw value (UTF-8), u64be(protocol version), u64be(connection epoch).
struct PeerPairingTranscript: Hashable, Sendable {
    let digest: [UInt8]

    init(host: PeerIdentityFingerprint, request: PeerPairingRequest, hostNonce: PeerNonce, peerNonce: PeerNonce) {
        digest = PeerTrustDigest.sha256(domain: "fluxklang.peer.pair.transcript.v1", [
            host.bytes, request.identity.bytes, request.commitment.bytes, hostNonce.bytes, peerNonce.bytes,
            Array(request.requestedRole.rawValue.utf8),
            PeerTrustDigest.bigEndian(UInt64(request.session.protocolVersion)),
            PeerTrustDigest.bigEndian(UInt64(request.session.connectionEpoch.value))
        ])
    }
}

/// Six decimal digits for a person to compare, read digit by digit. It can only
/// be made from a whole transcript: the first 8 digest bytes as a u64be value,
/// modulo 1 000 000, rendered as exactly six digits with leading zeros.
struct PeerConfirmationCode: Hashable, Sendable, CustomStringConvertible {
    static let digitCount = 6

    let digits: String

    init(_ transcript: PeerPairingTranscript) {
        let prefix = transcript.digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let value = String(prefix % 1_000_000)
        digits = String(repeating: "0", count: Self.digitCount - value.count) + value
    }

    var description: String { digits }
}
