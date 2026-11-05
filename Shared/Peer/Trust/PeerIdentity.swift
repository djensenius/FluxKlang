//
//  PeerIdentity.swift
//  FluxKlang
//
//  Peer identity material for pairing and trust (#94). Identity is a full
//  32-byte fingerprint supplied by the authenticated transport, never taken
//  from hello bytes and never from a short confirmation code. None of these
//  types are `Encodable`: trust material never enters JSON, project files or
//  synced (iCloud) storage. `PeerTrustTests+Storage` fails if that changes.
//

import CryptoKit
import Foundation

/// The full identity of a peer: the SHA-256 of its public key as reported by
/// the authenticated transport. Compared byte for byte.
struct PeerIdentityFingerprint: Hashable, Sendable, CustomStringConvertible {
    static let byteCount = 32

    let bytes: [UInt8]

    init?(_ bytes: some Sequence<UInt8>) {
        let bytes = Array(bytes)
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// Redacted: enough to tell peers apart in diagnostics, not the full identity.
    var description: String { "peer:" + PeerTrustDigest.hex(bytes.prefix(4)) + "…" }
}

/// A 32-byte single-use pairing nonce. The host's nonce must come from a
/// cryptographically secure source; the pure model only checks freshness.
struct PeerNonce: Hashable, Sendable {
    static let byteCount = 32

    let bytes: [UInt8]

    init?(_ bytes: some Sequence<UInt8>) {
        let bytes = Array(bytes)
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }
}

/// Domain-separated SHA-256 over length-prefixed parts, so no two different
/// part lists share an input. Byte layout (a wire contract; both peers must agree):
///
///     SHA-256( u64be(len(domain)) ‖ domain-UTF-8 ‖ for each part: u64be(len(part)) ‖ part )
///
/// `u64be` is an unsigned 64-bit big-endian integer. Fixed vectors are pinned
/// in `PeerTrustTests+Vectors`.
enum PeerTrustDigest {
    static func sha256(domain: String, _ parts: [[UInt8]]) -> [UInt8] {
        var hasher = SHA256()
        for part in [Array(domain.utf8)] + parts {
            hasher.update(data: bigEndian(UInt64(part.count)))
            hasher.update(data: part)
        }
        return Array(hasher.finalize())
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef")
        return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
    }

    static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) }
    }
}
