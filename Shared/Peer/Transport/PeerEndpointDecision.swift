//
//  PeerEndpointDecision.swift
//  FluxKlang
//
//  Typed refusals and the allow/deny outcome of the peer endpoint policy
//  (#93, slice P4). Pure values; no sockets, no text parsing, no probing.
//

/// Every way an endpoint address, a mask, a policy or a decision can refuse.
enum PeerEndpointRefusal: Hashable, Sendable, Error {
    /// The octet array is not 4 (IPv4) or 16 (IPv6) bytes long.
    case badLength(count: Int)
    /// The port is 0. Ports 1...65535 are valid.
    case badPort
    /// A zone index was given on an address that is not a native IPv6 link-local address.
    case zoneNotAllowed
    /// The zone index is 0; a link-local zone is 1 or more, `nil` means no zone.
    case badZone
    /// A mask prefix is outside `0...maximum` for its family (`maximum` is 32 or 128).
    case badPrefix(bits: Int, maximum: Int)
    /// More denied masks than `PeerEndpointPolicy.maximumDenied`.
    case tooManyDenied(limit: Int)
    /// The policy re-validation at the point of use failed (`deniedCount` is the offending count).
    case invalidPolicy(deniedCount: Int)
    /// The address matched a denied mask; `maskIndex` is the lowest matching index.
    case denied(maskIndex: Int)
    /// The origin is manual and the policy does not allow manual entry.
    case manualEntryDisabled
    /// The address class is not in the policy's allowed classes.
    case classNotAllowed(PeerAddressClass)
    /// The policy requires local-link and the address is neither link-local nor an allowed loopback.
    case notLocalLink
}

/// The result of `PeerEndpointPolicy.decide`. A refusal never carries a partial allow.
enum PeerEndpointDecision: Hashable, Sendable {
    case allowed
    case refused(PeerEndpointRefusal)

    /// The acceptor availability this decision maps onto: allowed is `.available`, a denied-mask
    /// refusal is `.denied`, every other refusal is `.ineligible`.
    var mapsTo: PeerAcceptorAvailability {
        switch self {
        case .allowed: .available
        case .refused(.denied): .denied
        case .refused: .ineligible
        }
    }
}
