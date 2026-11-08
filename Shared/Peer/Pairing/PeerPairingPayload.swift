//
//  PeerPairingPayload.swift
//  FluxKlang
//
//  A non-secret locator for the host a person intends to pair with (#94 P2),
//  for example the contents of a QR code or a line to read aloud: the host's
//  full fingerprint and its label. It carries no nonce, no grant and no secret,
//  it is not `Codable`, and it is not a protocol step. The six-digit
//  confirmation code is not a fingerprint; this value is what lets a controller
//  check the transport's identity against the one the person meant.
//

struct PeerPairingPayload: Hashable, Sendable {
    /// Eight groups of eight hex digits cover all 64 digits of the 32-byte fingerprint.
    static let groupCount = 8
    static let groupWidth = 8

    let hostFingerprint: PeerIdentityFingerprint
    let hostLabel: String

    private init(hostFingerprint: PeerIdentityFingerprint, hostLabel: String) {
        self.hostFingerprint = hostFingerprint
        self.hostLabel = hostLabel
    }

    /// Labels are compared by their UTF-8 bytes, as the label rule measures them: `String ==` would treat
    /// `"\u{E9}"` and `"e\u{301}"` as one label.
    static func == (lhs: PeerPairingPayload, rhs: PeerPairingPayload) -> Bool {
        lhs.hostFingerprint == rhs.hostFingerprint && lhs.hostLabel.utf8.elementsEqual(rhs.hostLabel.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hostFingerprint)
        hasher.combine(hostLabel.utf8.count)
        for byte in hostLabel.utf8 { hasher.combine(byte) }
    }

    /// Refuses with `.invalidLabel` a label `PeerPairingLabelRule` refuses.
    static func make(hostFingerprint: PeerIdentityFingerprint,
                     hostLabel: String) throws(PeerInitiatorError) -> PeerPairingPayload {
        guard PeerPairingLabelRule.isValid(hostLabel) else { throw .invalidLabel }
        return PeerPairingPayload(hostFingerprint: hostFingerprint, hostLabel: hostLabel)
    }

    /// The whole fingerprint as lowercase hex, `groupCount` groups of `groupWidth` digits.
    var fingerprintGroups: [String] {
        let digits = Array(PeerTrustDigest.hex(hostFingerprint.bytes))
        return stride(from: 0, to: digits.count, by: Self.groupWidth).map { start in
            String(digits[start..<min(start + Self.groupWidth, digits.count)])
        }
    }

    /// The groups joined by single spaces.
    var fingerprintDisplay: String { fingerprintGroups.joined(separator: " ") }

    /// Whether `transportIdentity` is the host this payload names. All 32 bytes are compared and the
    /// differences are accumulated before the answer, so the work does not depend on where bytes differ.
    func matches(_ transportIdentity: PeerIdentityFingerprint) -> Bool {
        let expected = hostFingerprint.bytes
        let found = transportIdentity.bytes
        guard expected.count == found.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ found[index] }
        return difference == 0
    }
}
