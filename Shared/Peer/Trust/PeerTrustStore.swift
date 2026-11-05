//
//  PeerTrustStore.swift
//  FluxKlang
//
//  The host-local trust store (#94 P1): in memory only, never `Codable`, never
//  synced. Persistence (Keychain, this-device-only) is coordinator-owned and
//  comes later. Every mutation bumps the store revision, and a record's
//  permission fingerprint covers its revision, so any grant, role, revocation
//  or re-pair change invalidates commands authorised under the old state.
//
//  Revocation is final: a revoked identity cannot pair again until the host
//  explicitly clears it. Revocations are never evicted. Trusted and revoked
//  records share one combined capacity of 64, so every trusted peer's future
//  revocation always fits; when it is reached, new pairings are refused
//  instead (fail closed).
//

/// Why a trust operation or session binding failed.
enum PeerTrustError: Error, Hashable, Sendable {
    case unknownIdentity
    case revoked
    case alreadyTrusted
    case notRevoked
    /// `maximumPeers` identities are already trusted.
    case capacityExceeded
    /// Pairing refused: `maximumRecords` identities are revoked. Revocations are
    /// never evicted; the host must clear one explicitly.
    case revocationListFull
    /// Pairing refused: trusted plus revoked records reached the combined
    /// `maximumRecords` capacity, which reserves room for every trusted peer's
    /// future revocation. Revocations are never evicted.
    case combinedRecordCapacityFull
    case invalidLabel
    case tooManyGrants(Int)
    case safetyNotGrantable
    case grantOutsideRole(PeerRole)
    case noCommandGrants
    case observerRequiresStatusRead
    case invalidProtocolVersion
    case versionDowngrade(floor: UInt16, negotiated: UInt16)
    case hostEpochMismatch
    case revisionExhausted
}

/// What the host knows about one trusted peer.
struct PeerTrustRecord: Hashable, Sendable {
    let identity: PeerIdentityFingerprint
    let label: String
    let grants: PeerGrantSet
    /// The protocol version paired over; a session may not negotiate lower.
    let protocolFloor: UInt16
    /// The store revision of this record's last change.
    let revision: Generation

    var role: PeerRole { grants.role }

    /// `"pt1."` + 64 lowercase hex digits (68 UTF-8 bytes) of
    /// `PeerTrustDigest.sha256(domain: "fluxklang.peer.permission.v1", parts)` where `parts` are, in order:
    /// identity (32 B), role raw value, u64be(command grant count), each command grant's canonical token
    /// (`"<class>|<scope kind>:<id>"`, sorted by UTF-8 bytes), u64be(read grant count), each read grant raw
    /// value (sorted), u64be(protocol floor), u64be(record revision). Contains no readable grant or identity.
    var permissionFingerprint: PermissionFingerprint {
        let commands = grants.commands.map(\.canonicalToken).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let reads = grants.reads.map(\.rawValue).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let parts: [[UInt8]] = [identity.bytes, Array(role.rawValue.utf8),
                                PeerTrustDigest.bigEndian(UInt64(commands.count))] + commands.map { Array($0.utf8) }
            + [PeerTrustDigest.bigEndian(UInt64(reads.count))] + reads.map { Array($0.utf8) }
            + [PeerTrustDigest.bigEndian(UInt64(protocolFloor)), PeerTrustDigest.bigEndian(UInt64(revision.value))]
        let digest = PeerTrustDigest.sha256(domain: "fluxklang.peer.permission.v1", parts)
        return PermissionFingerprint(rawValue: "pt1." + PeerTrustDigest.hex(digest))
    }
}

/// Host-local trusted peers and revocations.
struct PeerTrustStore: Hashable, Sendable {
    static let maximumPeers = 32
    /// Combined capacity for trusted plus revoked records (and so also the most revocations).
    static let maximumRecords = 64
    static let labelUTF8Bounds = 1...64

    private(set) var revision = Generation.initial
    private var records: [PeerIdentityFingerprint: PeerTrustRecord] = [:]
    private var revocations: Set<PeerIdentityFingerprint> = []

    var trustedCount: Int { records.count }
    var revokedCount: Int { revocations.count }

    func record(for identity: PeerIdentityFingerprint) -> PeerTrustRecord? { records[identity] }

    func isRevoked(_ identity: PeerIdentityFingerprint) -> Bool { revocations.contains(identity) }

    /// Whether `identity` may start pairing now.
    func checkPairable(_ identity: PeerIdentityFingerprint) throws(PeerTrustError) {
        guard !revocations.contains(identity) else { throw .revoked }
        guard records[identity] == nil else { throw .alreadyTrusted }
        guard records.count < Self.maximumPeers else { throw .capacityExceeded }
        guard revocations.count < Self.maximumRecords else { throw .revocationListFull }
        // Every trusted peer may later be revoked; keep room for all of them.
        guard revocations.count + records.count < Self.maximumRecords else { throw .combinedRecordCapacityFull }
    }

    /// Trusts `identity` with `grants`. Only the host's pairing approval calls this.
    @discardableResult
    mutating func pair(_ identity: PeerIdentityFingerprint, label: String, grants: PeerGrantSet,
                       protocolFloor: UInt16) throws(PeerTrustError) -> PeerTrustRecord {
        try checkPairable(identity)
        guard Self.isValidLabel(label) else { throw .invalidLabel }
        guard protocolFloor >= 1 else { throw .invalidProtocolVersion }
        let revision = try bump()
        let record = PeerTrustRecord(identity: identity, label: label, grants: grants, protocolFloor: protocolFloor,
                                     revision: revision)
        records[identity] = record
        return record
    }

    /// Replaces a trusted peer's grants, including its role.
    @discardableResult
    mutating func updateGrants(_ identity: PeerIdentityFingerprint,
                               to grants: PeerGrantSet) throws(PeerTrustError) -> PeerTrustRecord {
        guard let existing = records[identity] else {
            throw revocations.contains(identity) ? .revoked : .unknownIdentity
        }
        let revision = try bump()
        let record = PeerTrustRecord(identity: identity, label: existing.label, grants: grants,
                                     protocolFloor: existing.protocolFloor, revision: revision)
        records[identity] = record
        return record
    }

    /// Revokes a trusted peer. Always succeeds for a trusted peer: room was
    /// reserved in the combined capacity when it paired. Nothing is evicted.
    mutating func revoke(_ identity: PeerIdentityFingerprint) throws(PeerTrustError) {
        guard records[identity] != nil else { throw revocations.contains(identity) ? .revoked : .unknownIdentity }
        _ = try bump()
        records[identity] = nil
        revocations.insert(identity)
    }

    /// The host's explicit decision to allow a revoked identity to pair again.
    mutating func clearRevocation(_ identity: PeerIdentityFingerprint) throws(PeerTrustError) {
        guard revocations.contains(identity) else { throw .notRevoked }
        _ = try bump()
        revocations.remove(identity)
    }

    private mutating func bump() throws(PeerTrustError) -> Generation {
        do {
            revision = try revision.next()
        } catch { throw .revisionExhausted }
        return revision
    }

    private static let refusedLabelCategories: Set<Unicode.GeneralCategory> = [
        .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned
    ]
    private static let combiningMarks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]
    private static let variationSelectors: ClosedRange<Unicode.Scalar> = "\u{FE00}"..."\u{FE0F}"

    /// A label must read as what it is: no control, format, separator,
    /// private-use or unassigned scalars, no default-ignorable scalar other
    /// than a variation selector (so emoji presentation works), at least one
    /// visible letter, number, punctuation or symbol, no leading combining
    /// mark and no leading or trailing whitespace. Refused, never trimmed.
    private static func isValidLabel(_ label: String) -> Bool {
        let scalars = label.unicodeScalars
        guard labelUTF8Bounds.contains(label.utf8.count), let first = scalars.first, let last = scalars.last,
              !first.properties.isWhitespace, !last.properties.isWhitespace,
              !combiningMarks.contains(first.properties.generalCategory) else { return false }
        let hidden = scalars.contains { scalar in
            refusedLabelCategories.contains(scalar.properties.generalCategory)
                || (scalar.properties.isDefaultIgnorableCodePoint && !variationSelectors.contains(scalar))
        }
        return !hidden && scalars.contains(where: isVisible)
    }

    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        guard !properties.isWhitespace, !properties.isDefaultIgnorableCodePoint else { return false }
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
