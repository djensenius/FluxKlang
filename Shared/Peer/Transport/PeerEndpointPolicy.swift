//
//  PeerEndpointPolicy.swift
//  FluxKlang
//
//  Deny masks and the endpoint policy (#93, slice P4). Denial is absolute and a
//  manual origin has no override path: a manual endpoint is evaluated by the
//  same rules plus `manualEntryAllowed`.
//
//  Refusal order in `decide`: invalid policy, denied mask, manual entry
//  disabled, class not allowed, local-link required.
//
//  A mask is matched against the address bytes of its own family. An IPv4-mapped
//  IPv6 address is matched by IPv4 masks on its embedded IPv4 bytes AND by IPv6
//  masks on its full 16 bytes (denial wins either way). A native IPv4 address is
//  matched by IPv4 masks only; a native IPv6 address by IPv6 masks only.
//

enum PeerEndpointOrigin: Hashable, Sendable { case discovered, manual }

/// A deny mask: a network prefix of 0...32 (IPv4) or 0...128 (IPv6) bits. Prefix 0 is a legal
/// deny-all of that family. Host bits beyond the prefix are zeroed, so equal networks are equal values.
struct PeerAddressMask: Hashable, Sendable {
    private(set) var octets: [UInt8]
    private(set) var prefixBits: Int

    private init(octets: [UInt8], prefixBits: Int) {
        self.octets = octets
        self.prefixBits = prefixBits
    }

    /// Refusal order: length (4 or 16), then prefix.
    static func make(octets: [UInt8], prefixBits: Int) throws(PeerEndpointRefusal) -> PeerAddressMask {
        guard octets.count == PeerEndpointAddress.ipv4Length || octets.count == PeerEndpointAddress.ipv6Length else {
            throw .badLength(count: octets.count)
        }
        let maximum = octets.count * 8
        guard (0...maximum).contains(prefixBits) else { throw .badPrefix(bits: prefixBits, maximum: maximum) }
        let kept = octets.enumerated().map { $0.element & keepMask(prefixBits: prefixBits, byteIndex: $0.offset) }
        return PeerAddressMask(octets: kept, prefixBits: prefixBits)
    }

    func matches(_ address: PeerEndpointAddress) -> Bool {
        var views: [[UInt8]] = []
        if let ipv4 = address.embeddedIPv4 { views.append(ipv4) }
        if address.octets.count == PeerEndpointAddress.ipv6Length { views.append(address.octets) }
        return views.contains { $0.count == octets.count && covers($0) }
    }

    private func covers(_ candidate: [UInt8]) -> Bool {
        octets.indices.allSatisfy { index in
            (candidate[index] ^ octets[index]) & Self.keepMask(prefixBits: prefixBits, byteIndex: index) == 0
        }
    }

    private static func keepMask(prefixBits: Int, byteIndex: Int) -> UInt8 {
        let bits = min(max(prefixBits - byteIndex * 8, 0), 8)
        return bits == 0 ? 0 : UInt8.max << UInt8(8 - bits)
    }
}

/// A policy built only through `make`. `decide` re-validates the rules it evaluates.
struct PeerEndpointPolicy: Hashable, Sendable {
    static let maximumDenied = 64

    /// The plain rule data. Any value can be built, which is why `evaluate` re-validates it.
    struct Rules: Hashable, Sendable {
        var allowedClasses: Set<PeerAddressClass>
        var denied: [PeerAddressMask]
        var requireLocalLink: Bool
        var manualEntryAllowed: Bool
    }

    private(set) var rules: Rules

    private init(rules: Rules) { self.rules = rules }

    var allowedClasses: Set<PeerAddressClass> { rules.allowedClasses }
    var denied: [PeerAddressMask] { rules.denied }
    var requireLocalLink: Bool { rules.requireLocalLink }
    var manualEntryAllowed: Bool { rules.manualEntryAllowed }

    /// An empty `allowedClasses` is legal and refuses every address. `denied` keeps the caller order.
    static func make(
        allowedClasses: Set<PeerAddressClass>,
        denied: [PeerAddressMask],
        requireLocalLink: Bool,
        manualEntryAllowed: Bool
    ) throws(PeerEndpointRefusal) -> PeerEndpointPolicy {
        guard denied.count <= maximumDenied else { throw .tooManyDenied(limit: maximumDenied) }
        let rules = Rules(
            allowedClasses: allowedClasses,
            denied: denied,
            requireLocalLink: requireLocalLink,
            manualEntryAllowed: manualEntryAllowed
        )
        return PeerEndpointPolicy(rules: rules)
    }

    func decide(_ address: PeerEndpointAddress, origin: PeerEndpointOrigin) -> PeerEndpointDecision {
        Self.evaluate(address, origin: origin, rules: rules)
    }

    static func evaluate(
        _ address: PeerEndpointAddress,
        origin: PeerEndpointOrigin,
        rules: Rules
    ) -> PeerEndpointDecision {
        if rules.denied.count > maximumDenied {
            return .refused(.invalidPolicy(deniedCount: rules.denied.count))
        }
        if let index = rules.denied.firstIndex(where: { $0.matches(address) }) {
            return .refused(.denied(maskIndex: index))
        }
        if origin == .manual && !rules.manualEntryAllowed {
            return .refused(.manualEntryDisabled)
        }
        let addressClass = address.classification
        if !rules.allowedClasses.contains(addressClass) {
            return .refused(.classNotAllowed(addressClass))
        }
        if rules.requireLocalLink && addressClass != .linkLocal && addressClass != .loopback {
            return .refused(.notLocalLink)
        }
        return .allowed
    }
}
