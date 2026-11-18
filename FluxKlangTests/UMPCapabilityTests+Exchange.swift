import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #83 "bounded profile/property discovery" (profiles, and the Property Exchange Capabilities Reply; property data is
/// not collected) and "Unique ID alone is not universal identity": MIDI-CI bytes → `MIDICIMessage` /
/// `MIDICIProfileMessage` / `MIDICIPropertyCapabilityMessage` → answer → negotiation.
extension UMPCapabilityTests {
    private static let midi2Packets = [endpointMIDI2, block0, block1]

    @Test func discoveryReplyAndProfileReplyBytesNegotiateProfiles() throws {
        let sent = try MIDICIMessage.decode(payload: Self.discovery, limits: .standard)
        guard case let .discovery(sentHeader, _) = sent else {
            Issue.record("not a Discovery: \(sent)")
            return
        }
        #expect(sentHeader.source.rawValue == 0x0123_4567)
        #expect(sentHeader.destination.isBroadcast)

        let received = try MIDICIMessage.decode(payload: Self.reply, limits: .standard)
        guard case let .discoveryReply(header, info, functionBlock) = received else {
            Issue.record("not a Discovery Reply: \(received)")
            return
        }
        #expect(header.source.rawValue == 0x0765_4321)
        #expect(header.destination == sentHeader.source)
        #expect(functionBlock == 0)
        #expect(info.identity.manufacturer == [0x00, 0x21, 0x09])
        #expect(info.identity.family == 0x0102)
        #expect(info.identity.model == 0x0003)
        #expect(info.identity.softwareRevision == [1, 0, 0, 0])
        #expect(info.capabilityCategory == 0x0E)
        #expect(info.maximumSysExSize == 512)
        #expect(info.outputPathID == 0)

        let result = try Self.negotiate(Self.midi2Packets, ci: [Self.reply, Self.profileReply])
        #expect(result.level == .umpMIDI2)
        #expect(result.features == [
            .umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks, .ciDiscovery, .profileConfiguration
        ])
        // Enabled [B, A] and disabled [C] arrive in wire order; the result is sorted by value.
        let expected = try [Self.profileB, Self.profileC, Self.profileA].map(MIDICapabilityProfileID.make(bytes:))
        #expect(result.profiles == expected)
        // Block 1 is a MIDI 1.0 block on this MIDI 2.0 endpoint (#572 gap 3).
        #expect(result.downgrades == [Self.block1MIDI1Only])
    }

    @Test func profilesWithoutTheCategoryBitAreIgnoredExplicitly() throws {
        let reply = Self.prefix(0x71) + Self.deviceMUID + Self.hostMUID + Self.silentBody + [0x00, 0x00]
        let result = try Self.negotiate(Self.midi2Packets, ci: [reply, Self.profileReply])
        #expect(result.level == .umpMIDI2)
        #expect(!result.features.contains(.profileConfiguration))
        #expect(result.profiles.isEmpty)
        #expect(result.downgrades == [
            Self.block1MIDI1Only,
            MIDICapabilityDowngrade(reason: .profilesNotAdvertised, lost: [.profileConfiguration],
                                    possibleTranslationLosses: [])
        ])
    }

    @Test func profileListsAreBoundedAtTheLimit() throws {
        let limit = MIDICapabilityLimits.maximumProfiles
        #expect(limit == 64)
        #expect(MIDICIProfileMessage.maximumProfilesPerList == limit)
        // At the limit, in either list: decoded and negotiated, nothing truncated.
        for (enabled, disabled) in [(limit, 0), (0, limit), (limit / 2, limit / 2)] {
            let payloads = [Self.reply, Self.profileReply(enabled: enabled, disabled: disabled)]
            #expect(try Self.negotiate(Self.midi2Packets, ci: payloads).profiles.count == limit)
        }
        // One over in a single list: refused by the decoder from the declared count.
        for (enabled, disabled) in [(limit + 1, 0), (0, limit + 1)] {
            let payload = Self.profileReply(enabled: enabled, disabled: disabled)
            #expect(throws: MIDICIRefusal.tooManyProfiles(count: limit + 1, limit: limit)) {
                try MIDICIProfileMessage.decode(payload: payload, limits: .standard)
            }
        }
        // A hostile declared count (0x3FFF) with no ids behind it is refused before any id is read.
        let hostile = Self.prefix(0x21) + Self.deviceMUID + Self.hostMUID + [0x7F, 0x7F]
        #expect(throws: MIDICIRefusal.tooManyProfiles(count: 0x3FFF, limit: limit)) {
            try MIDICIProfileMessage.decode(payload: hostile, limits: .standard)
        }
        // Each list within its bound but the two together over it: the decoder accepts, the adapter refuses the
        // combined count before building any facts (#572 gap 2).
        let split = Self.profileReply(enabled: limit, disabled: 1)
        _ = try MIDICIProfileMessage.decode(payload: split, limits: .standard)
        #expect(throws: MIDICapabilityDiscoveryRefusal.tooManyProfiles(count: limit + 1)) {
            try Self.facts(Self.midi2Packets, ci: [Self.reply, split])
        }
    }

    @Test func aProfileInBothListsIsRefusedAsADuplicate() throws {
        let both = Self.prefix(0x21) + Self.deviceMUID + Self.hostMUID
            + [0x01, 0x00] + Self.profileA + [0x01, 0x00] + Self.profileA
        // The adapter refuses a Reply that repeats an id inside itself before any facts are built.
        let refusal = MIDICapabilityDiscoveryRefusal.duplicateProfileInReply(
            device: .allCall, transport: .group(try UMPGroup(0)))
        #expect(throws: refusal) {
            try Self.facts(Self.midi2Packets, ci: [Self.reply, both])
        }
    }

    /// How identity is keyed: `MIDICapabilityCIAnswer.answered` keeps the `MIDICIDiscoveryInfo` (with its device
    /// identity) but no MUID, and the negotiated result carries neither: it describes one set of facts. The adapter's
    /// `MIDICapabilityPeer`, next to the facts, keeps the MUID and the device identity together. Endpoint identity
    /// is `MIDIEndpointKey` (`Shared/MIDI/IO/Registry/MIDIEndpointKey.swift`), an adapter-supplied fingerprint.
    @Test func sameMUIDWithAnotherDeviceIdentityIsNotConflated() throws {
        let other = Self.prefix(0x71) + Self.deviceMUID + Self.hostMUID + Self.otherBody + [0x00, 0x00]
        let first = try MIDICIMessage.decode(payload: Self.reply, limits: .standard)
        let second = try MIDICIMessage.decode(payload: other, limits: .standard)
        #expect(first.header == second.header)
        #expect(first != second)
        guard case let .discoveryReply(_, firstInfo, _) = first, case let .discoveryReply(_, secondInfo, _) = second
        else {
            Issue.record("not Discovery Replies: \(first), \(second)")
            return
        }
        #expect(firstInfo.identity != secondInfo.identity)
        #expect(secondInfo.identity.manufacturer == [0x00, 0x20, 0x6B])

        let firstAnswer = try Self.ciAnswer(reply: Self.reply)
        let secondAnswer = try Self.ciAnswer(reply: other)
        #expect(firstAnswer != secondAnswer)
        #expect(try Self.facts(Self.midi2Packets, ci: [Self.reply])
            != Self.facts(Self.midi2Packets, ci: [other]))
        // Equal capabilities negotiate equally: the result names no device, so it cannot merge two of them.
        #expect(try Self.negotiate(Self.midi2Packets, ci: [Self.reply])
            == Self.negotiate(Self.midi2Packets, ci: [other]))
        // The peers share the MUID and differ by device identity.
        let firstPeer = try Self.discovery(Self.midi2Packets, ci: [Self.reply]).peer
        let secondPeer = try Self.discovery(Self.midi2Packets, ci: [other]).peer
        #expect(firstPeer.muid == secondPeer.muid)
        #expect(firstPeer.ciIdentity == firstInfo.identity)
        #expect(secondPeer.ciIdentity == secondInfo.identity)
        #expect(firstPeer != secondPeer)
    }

    // MARK: - Property Exchange Capabilities

    /// MUID 0x088CD111: neither the host nor the device.
    private static let strangerMUID: [UInt8] = [0x11, 0x22, 0x33, 0x44]

    /// Property Exchange Capabilities bytes, written by hand: `7E, device, 0D, subID, format` then source,
    /// destination and body. One body byte is CI 1.1 (format 01); three are CI 1.2 (format 02).
    private static func property(
        _ subID: UInt8 = 0x31, device: UInt8 = 0x7F, source: [UInt8] = deviceMUID, destination: [UInt8] = hostMUID,
        body: [UInt8] = [0x04, 0x00, 0x00]
    ) -> [UInt8] {
        [0x7E, device, 0x0D, subID, body.count == 1 ? 0x01 : 0x02] + source + destination + body
    }

    /// The adapter's refusal for `payload`, or nil when it is not refused; a decoder refusal is thrown.
    private static func refusal(
        collecting payload: [UInt8], into discovery: inout MIDICapabilityDiscovery
    ) throws -> MIDICapabilityDiscoveryRefusal? {
        do {
            try collect(ci: payload, into: &discovery)
            return nil
        } catch let refusal as MIDICapabilityDiscoveryRefusal {
            return refusal
        }
    }

    @Test func propertyCapabilitiesReplyBytesAreCollectedFromThePeer() throws {
        #expect(Self.property() == Self.propertyReply)
        var discovery = try Self.discovery(Self.midi2Packets, ci: [Self.reply, Self.profileReply])
        let before = discovery
        #expect(before.propertyCapabilities == nil)
        let outcome = try Self.collect(ci: Self.propertyReply, into: &discovery)
        #expect(outcome == .recorded)
        let kept = try #require(discovery.propertyCapabilities)
        #expect(kept.simultaneousRequests == 4)
        let version = try #require(kept.version)
        #expect(version == (try MIDICIPropertyExchangeVersion.make(major: 0, minor: 0)))
        // Kept beside the facts: the facts, the negotiation and the peer are those of the same bytes without it.
        #expect(discovery.facts == before.facts)
        #expect(discovery.peer == before.peer)
        #expect(try Self.negotiate(Self.midi2Packets, ci: [Self.reply, Self.profileReply, Self.propertyReply])
            == Self.negotiate(Self.midi2Packets, ci: [Self.reply, Self.profileReply]))
    }

    @Test func aCI11PropertyCapabilitiesReplyKeepsNoVersion() throws {
        #expect(Self.property(body: [0x04]) == Self.propertyReply11)
        var discovery = try Self.discovery(Self.midi2Packets, ci: [Self.reply])
        let outcome = try Self.collect(ci: Self.propertyReply11, into: &discovery)
        #expect(outcome == .recorded)
        let kept = try #require(discovery.propertyCapabilities)
        #expect(kept.simultaneousRequests == 4)
        #expect(kept.version == nil)
        // The CI 1.2 form of the same count carries a version, so it is another Reply.
        let after = discovery
        let refusal = try Self.refusal(collecting: Self.propertyReply, into: &discovery)
        #expect(refusal == .conflictingPropertyCapabilities(try MIDICIMUID.make(0x0765_4321)))
        #expect(discovery == after)
    }

    @Test func propertyCapabilitiesBeforeTheDiscoveryReplyAreIgnored() throws {
        var discovery = try Self.discovery(Self.midi2Packets)
        let before = discovery
        let early = try Self.collect(ci: Self.propertyReply, into: &discovery)
        #expect(early == .ignored(.beforeDiscoveryReply))
        #expect(discovery == before)
        // Not even at another address: there is no peer yet to refuse it for.
        let elsewhere = try Self.collect(ci: Self.property(device: 0x00), into: &discovery)
        #expect(elsewhere == .ignored(.beforeDiscoveryReply))
        #expect(discovery == before)
        try Self.collect(ci: Self.reply, into: &discovery)
        let late = try Self.collect(ci: Self.propertyReply, into: &discovery)
        #expect(late == .recorded)
    }

    /// The source MUID is checked before the address: a stranger at 0x7E is ignored, not refused.
    @Test func propertyCapabilitiesFromAnotherMUIDAreIgnoredWhateverTheAddress() throws {
        let stranger = try MIDICIMUID.make(0x088C_D111)
        var discovery = try Self.discovery(Self.midi2Packets, ci: [Self.reply])
        let before = discovery
        for device: UInt8 in [0x7E, 0x7F, 0x00] {
            let payload = Self.property(device: device, source: Self.strangerMUID)
            let outcome = try Self.collect(ci: payload, into: &discovery)
            #expect(outcome == .ignored(.otherMUID(stranger)), "device \(device)")
            #expect(discovery == before, "device \(device)")
        }
    }

    @Test func withAHostMUIDPropertyCapabilitiesAddressedElsewhereAreIgnored() throws {
        let elsewhere = Self.property(destination: Self.strangerMUID)
        let ignored = MIDICapabilityDiscoveryOutcome.ignored(.otherDestination(try MIDICIMUID.make(0x088C_D111)))
        let fresh = MIDICapabilityDiscovery(host: try MIDICIMUID.make(0x0123_4567))
        var discovery = fresh
        // The destination comes first, even before the peer is known.
        let early = try Self.collect(ci: elsewhere, into: &discovery)
        #expect(early == ignored)
        #expect(discovery == fresh)
        try Self.collect(ci: Self.reply, into: &discovery)
        let before = discovery
        let outcome = try Self.collect(ci: elsewhere, into: &discovery)
        #expect(outcome == ignored)
        #expect(discovery == before)
        let broadcast = try Self.collect(ci: Self.property(destination: Self.broadcastMUID), into: &discovery)
        #expect(broadcast == .recorded)
        // Without a host MUID no destination is checked.
        var open = try Self.discovery([], ci: [Self.reply])
        let unchecked = try Self.collect(ci: elsewhere, into: &open)
        #expect(unchecked == .recorded)
    }

    @Test func propertyCapabilitiesAwayFromTheFunctionBlockAreRefused() throws {
        var discovery = try Self.discovery(Self.midi2Packets, ci: [Self.reply])
        for device: UInt8 in [0x00, 0x7E] {
            let before = discovery
            let refusal = try Self.refusal(collecting: Self.property(device: device), into: &discovery)
            #expect(refusal == .propertyCapabilitiesNotAtFunctionBlock(device: try SysExDeviceID(device)))
            #expect(discovery == before)
        }
        #expect(discovery.propertyCapabilities == nil)
        // Once one is kept, an otherwise identical Reply away from 0x7F is still refused and changes nothing.
        try Self.collect(ci: Self.propertyReply, into: &discovery)
        let kept = discovery
        let refusal = try Self.refusal(
            collecting: Self.property(device: 0x00, body: [0x05, 0x00, 0x00]), into: &discovery)
        #expect(refusal == .propertyCapabilitiesNotAtFunctionBlock(device: try SysExDeviceID(0x00)))
        #expect(discovery == kept)
    }

    @Test func aPropertyCapabilitiesRepeatIsIdempotentAndADifferentOneIsRefused() throws {
        var discovery = try Self.discovery(Self.midi2Packets, ci: [Self.reply, Self.propertyReply])
        let first = discovery
        let repeated = try Self.collect(ci: Self.propertyReply, into: &discovery)
        #expect(repeated == .repeated)
        #expect(discovery == first)
        let conflict = MIDICapabilityDiscoveryRefusal.conflictingPropertyCapabilities(try MIDICIMUID.make(0x0765_4321))
        for body: [UInt8] in [[0x05, 0x00, 0x00], [0x04, 0x00, 0x01]] {
            let refusal = try Self.refusal(collecting: Self.property(body: body), into: &discovery)
            #expect(refusal == conflict, "body \(body)")
            #expect(discovery == first, "body \(body)")
        }
        let kept = try #require(discovery.propertyCapabilities)
        #expect(kept.simultaneousRequests == 4)
        #expect(kept.version == (try MIDICIPropertyExchangeVersion.make(major: 0, minor: 0)))
    }

    /// The Inquiry decodes through `MIDICIPropertyCapabilityMessage`; a NAK to it (original sub-id 0x30) is a
    /// `MIDICIMessage` NAK. Neither is collected, before or after a Reply.
    @Test func thePropertyCapabilitiesInquiryAndItsNAKAreNotCollected() throws {
        let inquiries = [
            Self.property(0x30, source: Self.hostMUID, destination: Self.deviceMUID),
            Self.property(0x30)
        ]
        let nak = Self.prefix(0x7F) + Self.deviceMUID + Self.hostMUID + [0x30, 0x00, 0x00, 0, 0, 0, 0, 0, 0x00, 0x00]
        guard case .nak = try MIDICIMessage.decode(payload: nak, limits: .standard) else {
            Issue.record("not a NAK")
            return
        }
        var discovery = try Self.discovery(Self.midi2Packets, ci: [Self.reply])
        for kept in [false, true] {
            if kept { try Self.collect(ci: Self.propertyReply, into: &discovery) }
            let before = discovery
            for payload in inquiries + [nak] {
                let outcome = try Self.collect(ci: payload, into: &discovery)
                #expect(outcome == .ignored(.notCollected), "\(payload)")
                #expect(discovery == before, "\(payload)")
            }
        }
        let survivor = try #require(discovery.propertyCapabilities)
        #expect(survivor.simultaneousRequests == 4)
    }
}
