/// Who answered a capability discovery. MIDI-CI says a MUID alone is not a universal identity (it is chosen at
/// random and may be reassigned), so the peer keeps the MUID together with both device identities it was given.
/// It sits next to the facts and is never an input of `MIDICapabilityResolver`.
struct MIDICapabilityPeer: Equatable, Sendable {
    /// The source MUID of the first collected Discovery Reply; nil until one is collected.
    let muid: MIDICIMUID?
    /// The device identity (manufacturer, family, model, software revision) of that Discovery Reply.
    let ciIdentity: MIDICIDeviceIdentity?
    /// The UMP Stream Device Identity Notification, when one was collected.
    let streamIdentity: UMPStreamDeviceIdentity?
}

/// Every refusal from `MIDICapabilityDiscovery.collect`. A refusal leaves the discovery exactly as it was: the
/// caller decides whether to keep it, start again or give up. Nothing is repaired, merged or truncated.
enum MIDICapabilityDiscoveryRefusal: Error, Equatable, Sendable {
    /// An Endpoint Info that differs from the one already collected.
    case conflictingEndpointInfo(kept: UMPStreamEndpointInfo, received: UMPStreamEndpointInfo)
    /// A UMP Stream Device Identity that differs from the one already collected.
    case conflictingDeviceIdentity(kept: UMPStreamDeviceIdentity, received: UMPStreamDeviceIdentity)
    /// A Function Block Info with this index differs from the one already collected for it.
    case conflictingFunctionBlock(index: Int)
    /// A new block index would make this many blocks, more than `MIDICapabilityLimits.maximumFunctionBlocks`.
    case tooManyFunctionBlocks(count: Int)
    /// A Discovery Reply from the peer's MUID whose body or function block byte differs from the first one.
    case conflictingDiscoveryReply(MIDICIMUID)
    /// A Discovery Reply at an address (device id) other than the function block or whole port (0x7F), before the
    /// peer is known or from the peer. Discovery is always addressed to 0x7F, so such a reply is malformed and never
    /// fixes the peer.
    case discoveryReplyNotAtFunctionBlock(device: SysExDeviceID)
    /// A Reply to Profile Inquiry at a new address would bring the ids stored over every address (enabled and
    /// disabled together) above `MIDICapabilityLimits.maximumProfiles`; `count` is that would-be total.
    case tooManyProfiles(count: Int)
    /// A Reply to Profile Inquiry from the peer's MUID at an address that already has one, with a different enabled
    /// list, disabled list or split between them.
    case conflictingProfileReply(MIDICIMUID, address: SysExDeviceID)
    /// A Reply to Profile Inquiry from the peer at this address that lists one id more than once over its enabled and
    /// disabled lists together.
    case duplicateProfileInReply(device: SysExDeviceID)
}

/// Why `collect` kept nothing from a message.
enum MIDICapabilityDiscoveryIgnoreReason: Equatable, Sendable {
    /// The message carries no capability fact: a request, a name, a report, an ACK or a NAK, for example.
    case notCollected
    /// A collected MIDI-CI message addressed to this MUID, which is neither the host's nor the broadcast MUID (only
    /// when the discovery was made with a host MUID).
    case otherDestination(MIDICIMUID)
    /// A MIDI-CI message from a MUID other than the peer's (the source of the first Discovery Reply).
    case otherMUID(MIDICIMUID)
    /// A Reply to Profile Inquiry before any Discovery Reply: there is no peer yet to attribute it to.
    case beforeDiscoveryReply
}

/// What `collect` did with a message that it did not refuse.
enum MIDICapabilityDiscoveryOutcome: Equatable, Sendable {
    /// The message added a fact.
    case recorded
    /// The message repeated a fact already collected, exactly; nothing changed.
    case repeated
    /// The message changed nothing, for this reason.
    case ignored(MIDICapabilityDiscoveryIgnoreReason)
}

/// The production adapter from decoded UMP Stream and MIDI-CI messages to `MIDICapabilityFacts`. A pure value: it
/// never talks to a device, keeps no clock and holds at most one Endpoint Info, one Device Identity,
/// `MIDICapabilityLimits.maximumFunctionBlocks` blocks, one Discovery Reply, one Profile Reply per address (128 at
/// most, one per 7-bit device id) and `MIDICapabilityLimits.maximumProfiles` profile ids over all of them. The caller
/// feeds it the messages of one connection (the UMP endpoint and the MIDI-CI exchange on it) in arrival order;
/// decoding and timeouts stay with the caller.
///
/// One rule per piece of state (see the `collect` overloads):
/// - Endpoint Info and UMP Device Identity: the first is kept; an identical repeat is `.repeated`; a different one is
///   refused (`conflictingEndpointInfo`, `conflictingDeviceIdentity`). Last-wins never hides a conflict.
/// - Function Block Info: keyed by block index. An identical repeat is `.repeated`; a different block with a known
///   index is `conflictingFunctionBlock`; a new index beyond `maximumFunctionBlocks` blocks is
///   `tooManyFunctionBlocks`. The facts list the blocks by ascending index.
/// - Destination: when `host` is given, a Discovery Reply or Profile Reply addressed to neither `host` nor the
///   broadcast MUID is ignored with `otherDestination`. Without `host`, no destination is checked.
/// - Discovery Reply: Discovery is always addressed to the function block or whole port (device id 0x7F), so a
///   Discovery Reply at any other address, before the peer is known or from the peer, is refused with
///   `discoveryReplyNotAtFunctionBlock`; it never fixes the peer. The first one at 0x7F fixes the peer (its source
///   MUID and CI device identity). Any later MIDI-CI message from another MUID, whatever its address, is ignored
///   with `otherMUID`, never refused: on a shared MIDI-CI port several devices may answer one broadcast Discovery,
///   and only the first is described. A repeat from the peer is `.repeated` when identical (body and function block
///   byte) and `conflictingDiscoveryReply` otherwise.
/// - Reply to Profile Inquiry: from the peer only (`beforeDiscoveryReply` and `otherMUID` otherwise), keyed by its
///   address (the header's device id: 0x7F function block or whole port, 0x7E group, 0x00 to 0x0F a channel). A
///   MIDI-CI 1.2 inquiry to the function block is answered with one Reply per address, so each address is kept on
///   its own, with its enabled and disabled lists as received. A Reply that lists an id more than once (enabled and
///   disabled together) is refused with `duplicateProfileInReply` before anything is stored. At an address that
///   already has a Reply, an identical one is `.repeated` and any other (other ids, other order or another
///   enabled/disabled split) is `conflictingProfileReply`. At a new address, the would-be total of ids over every
///   address is checked before anything is stored (`tooManyProfiles`).
/// - NAK, and no reply at all: both leave the answer `.missing` (the documented `MIDICapabilityCIAnswer` rule). A NAK
///   is `.ignored(.notCollected)` and never removes a Discovery Reply already collected.
/// For a collected MIDI-CI message the destination check comes first. A Discovery Reply then has its source MUID
/// checked once a peer is known (another MUID is ignored), then its address. A Profile Reply then has its source
/// MUID checked, then duplicates inside it, then the address repeat or conflict check, then the count. A refusal
/// stores nothing.
///
/// The facts' profile list is the union over addresses in address order (`addressRank`: function block first, then
/// group, then channels ascending), each Reply contributing its enabled then its disabled ids. An id already given by
/// an earlier address is dropped (first occurrence wins): a profile supported on several addresses is one profile to
/// the resolver, which looks only at which ids are advertised and never at enabled versus disabled, so an id enabled
/// on one address and disabled on another is simply advertised. A Reply with a duplicate inside it is refused when
/// collected, so this union only ever drops ids seen at an earlier address and never hides a malformed Reply.
struct MIDICapabilityDiscovery: Equatable, Sendable {
    struct Reply: Equatable, Sendable {
        let muid: MIDICIMUID
        let address: SysExDeviceID
        let info: MIDICIDiscoveryInfo
        let functionBlock: UInt8?
    }

    /// One Reply to Profile Inquiry, as received at one address.
    struct ProfileReply: Equatable, Sendable {
        let address: SysExDeviceID
        let enabled: [MIDICapabilityProfileID]
        let disabled: [MIDICapabilityProfileID]
    }

    /// The MUID of this host, when the caller knows it: replies addressed elsewhere are then ignored.
    let host: MIDICIMUID?
    private(set) var endpoint: UMPStreamEndpointInfo?
    private(set) var streamIdentity: UMPStreamDeviceIdentity?
    /// Sorted by ascending index, one block per index.
    private(set) var blocks: [UMPStreamFunctionBlockInfo] = []
    private(set) var reply: Reply?
    /// The peer's Profile Replies, one per address, sorted by `addressRank`.
    private(set) var profileReplies: [ProfileReply] = []

    init(host: MIDICIMUID? = nil) {
        self.host = host
    }

    /// 0 for the function block or whole port (0x7F), 1 for the group (0x7E), then 2 plus the raw value: the channels
    /// 0x00 to 0x0F ascending, followed by any other device id ascending.
    static func addressRank(_ address: SysExDeviceID) -> Int {
        switch address.rawValue {
        case 0x7F: return 0
        case 0x7E: return 1
        case let raw: return 2 + Int(raw)
        }
    }

    /// The ids stored over every address, enabled and disabled together: every stored copy counts, before the
    /// cross-address de-duplication of `advertisedProfiles`.
    var storedProfileCount: Int {
        profileReplies.reduce(0) { $0 + $1.enabled.count + $1.disabled.count }
    }

    /// The union described on the type: address order, enabled then disabled, an id from an earlier address dropped.
    var advertisedProfiles: [MIDICapabilityProfileID] {
        var union: [MIDICapabilityProfileID] = []
        var earlier = Set<MIDICapabilityProfileID>()
        for stored in profileReplies {
            let ids = stored.enabled + stored.disabled
            union += ids.filter { !earlier.contains($0) }
            earlier.formUnion(ids)
        }
        return union
    }

    /// The resolver's only input. The CI answer is `.answered` once a Discovery Reply was collected (with
    /// `advertisedProfiles`, empty when no Profile Reply came) and `.missing` otherwise.
    var facts: MIDICapabilityFacts {
        let answer: MIDICapabilityCIAnswer
        if let reply {
            answer = .answered(reply.info, profiles: advertisedProfiles)
        } else {
            answer = .missing
        }
        return MIDICapabilityFacts(endpoint: endpoint, functionBlocks: blocks, ciAnswer: answer)
    }

    var peer: MIDICapabilityPeer {
        MIDICapabilityPeer(muid: reply?.muid, ciIdentity: reply?.info.identity, streamIdentity: streamIdentity)
    }
}

// MARK: - Collect

extension MIDICapabilityDiscovery {
    /// Collects Endpoint Info, Function Block Info and Device Identity; every other Stream message is
    /// `.ignored(.notCollected)`.
    @discardableResult
    mutating func collect(
        _ message: UMPStreamMessage
    ) throws(MIDICapabilityDiscoveryRefusal) -> MIDICapabilityDiscoveryOutcome {
        switch message {
        case .endpointInfo(let info):
            return try collectEndpoint(info)
        case .deviceIdentity(let identity):
            return try collectStreamIdentity(identity)
        case .functionBlockInfo(let block):
            return try collectBlock(block)
        case .endpointDiscovery, .endpointName, .productInstanceID, .streamConfigRequest, .streamConfigNotification,
             .functionBlockDiscovery, .functionBlockName, .startOfClip, .endOfClip:
            return .ignored(.notCollected)
        }
    }

    /// Collects a Discovery Reply; Discovery, Invalidate MUID, ACK and NAK are `.ignored(.notCollected)` (a NAK
    /// leaves the answer as it is, so `.missing` when no reply came).
    @discardableResult
    mutating func collect(
        _ message: MIDICIMessage
    ) throws(MIDICapabilityDiscoveryRefusal) -> MIDICapabilityDiscoveryOutcome {
        switch message {
        case let .discoveryReply(header, info, functionBlock):
            if let ignored = ignoredDestination(header) { return .ignored(ignored) }
            if let peer = reply?.muid, header.source != peer { return .ignored(.otherMUID(header.source)) }
            guard header.device == .allCall else { throw .discoveryReplyNotAtFunctionBlock(device: header.device) }
            return try collectReply(
                Reply(muid: header.source, address: header.device, info: info, functionBlock: functionBlock))
        case .discovery, .invalidateMUID, .ack, .nak:
            return .ignored(.notCollected)
        }
    }

    /// Collects a Reply to Profile Inquiry from the peer; the Inquiry and the four reports are
    /// `.ignored(.notCollected)`.
    @discardableResult
    mutating func collect(
        _ message: MIDICIProfileMessage
    ) throws(MIDICapabilityDiscoveryRefusal) -> MIDICapabilityDiscoveryOutcome {
        switch message {
        case let .inquiryReply(header, enabled, disabled):
            if let ignored = ignoredDestination(header) { return .ignored(ignored) }
            return try collectProfiles(header, enabled: enabled, disabled: disabled)
        case .inquiry, .enabledReport, .disabledReport, .addedReport, .removedReport:
            return .ignored(.notCollected)
        }
    }

    private mutating func collectEndpoint(
        _ info: UMPStreamEndpointInfo
    ) throws(MIDICapabilityDiscoveryRefusal) -> MIDICapabilityDiscoveryOutcome {
        guard let kept = endpoint else {
            endpoint = info
            return .recorded
        }
        guard kept == info else { throw .conflictingEndpointInfo(kept: kept, received: info) }
        return .repeated
    }

    private mutating func collectStreamIdentity(
        _ identity: UMPStreamDeviceIdentity
    ) throws(MIDICapabilityDiscoveryRefusal) -> MIDICapabilityDiscoveryOutcome {
        guard let kept = streamIdentity else {
            streamIdentity = identity
            return .recorded
        }
        guard kept == identity else { throw .conflictingDeviceIdentity(kept: kept, received: identity) }
        return .repeated
    }

    private mutating func collectBlock(
        _ block: UMPStreamFunctionBlockInfo
    ) throws(MIDICapabilityDiscoveryRefusal) -> MIDICapabilityDiscoveryOutcome {
        if let kept = blocks.first(where: { $0.index == block.index }) {
            guard kept == block else { throw .conflictingFunctionBlock(index: block.index) }
            return .repeated
        }
        guard blocks.count < MIDICapabilityLimits.maximumFunctionBlocks else {
            throw .tooManyFunctionBlocks(count: blocks.count + 1)
        }
        let position = blocks.firstIndex { $0.index > block.index } ?? blocks.endIndex
        blocks.insert(block, at: position)
        return .recorded
    }

    private mutating func collectReply(_ received: Reply) throws(MIDICapabilityDiscoveryRefusal)
        -> MIDICapabilityDiscoveryOutcome {
        guard let kept = reply else {
            reply = received
            return .recorded
        }
        guard kept.muid == received.muid else { return .ignored(.otherMUID(received.muid)) }
        guard kept == received else { throw .conflictingDiscoveryReply(kept.muid) }
        return .repeated
    }

    private func ignoredDestination(_ header: MIDICIHeader) -> MIDICapabilityDiscoveryIgnoreReason? {
        guard let host, header.destination != host, !header.destination.isBroadcast else { return nil }
        return .otherDestination(header.destination)
    }

    private mutating func collectProfiles(
        _ header: MIDICIHeader, enabled: [MIDICapabilityProfileID], disabled: [MIDICapabilityProfileID]
    ) throws(MIDICapabilityDiscoveryRefusal) -> MIDICapabilityDiscoveryOutcome {
        guard let peerMUID = reply?.muid else { return .ignored(.beforeDiscoveryReply) }
        guard header.source == peerMUID else { return .ignored(.otherMUID(header.source)) }
        let address = header.device
        let ids = enabled + disabled
        guard Set(ids).count == ids.count else { throw .duplicateProfileInReply(device: address) }
        if let kept = profileReplies.first(where: { $0.address == address }) {
            guard kept.enabled == enabled, kept.disabled == disabled else {
                throw .conflictingProfileReply(peerMUID, address: address)
            }
            return .repeated
        }
        let total = storedProfileCount + enabled.count + disabled.count
        guard total <= MIDICapabilityLimits.maximumProfiles else { throw .tooManyProfiles(count: total) }
        let rank = Self.addressRank(address)
        let position = profileReplies.firstIndex { Self.addressRank($0.address) > rank } ?? profileReplies.endIndex
        profileReplies.insert(ProfileReply(address: address, enabled: enabled, disabled: disabled), at: position)
        return .recorded
    }
}
