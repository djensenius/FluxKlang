import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// #83 "bounded profile/property discovery" (profiles only: property exchange has no codec yet) and "Unique ID alone
/// is not universal identity": MIDI-CI bytes → `MIDICIMessage` / `MIDICIProfileMessage` → answer → negotiation.
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
}
