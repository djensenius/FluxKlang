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

        let result = try Self.negotiate(
            Self.midi2Packets, answer: Self.ciAnswer(reply: Self.reply, profiles: Self.profileReply))
        #expect(result.level == .umpMIDI2)
        #expect(result.features == [
            .umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks, .ciDiscovery, .profileConfiguration
        ])
        // Enabled [B, A] and disabled [C] arrive in wire order; the result is sorted by value.
        let expected = try [Self.profileB, Self.profileC, Self.profileA].map(MIDICapabilityProfileID.make(bytes:))
        #expect(result.profiles == expected)
        #expect(result.downgrades.isEmpty)
    }

    @Test func profilesWithoutTheCategoryBitAreIgnoredExplicitly() throws {
        let reply = Self.prefix(0x71) + Self.deviceMUID + Self.hostMUID + Self.silentBody + [0x00, 0x00]
        let result = try Self.negotiate(
            Self.midi2Packets, answer: Self.ciAnswer(reply: reply, profiles: Self.profileReply))
        #expect(result.level == .umpMIDI2)
        #expect(!result.features.contains(.profileConfiguration))
        #expect(result.profiles.isEmpty)
        #expect(result.downgrades == [
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
            let answer = try Self.ciAnswer(
                reply: Self.reply, profiles: Self.profileReply(enabled: enabled, disabled: disabled))
            #expect(try Self.negotiate(Self.midi2Packets, answer: answer).profiles.count == limit)
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
        // Each list within its bound but the two together over it: the decoder accepts, the resolver refuses.
        let split = try Self.ciAnswer(reply: Self.reply, profiles: Self.profileReply(enabled: limit, disabled: 1))
        let facts = try Self.facts(Self.midi2Packets, answer: split)
        #expect(Self.refusal(facts) == .tooManyProfiles(count: limit + 1))
    }

    @Test func aProfileInBothListsIsRefusedAsADuplicate() throws {
        let both = Self.prefix(0x21) + Self.deviceMUID + Self.hostMUID
            + [0x01, 0x00] + Self.profileA + [0x01, 0x00] + Self.profileA
        let facts = try Self.facts(Self.midi2Packets, answer: Self.ciAnswer(reply: Self.reply, profiles: both))
        #expect(Self.refusal(facts) == .duplicateProfile(try MIDICapabilityProfileID.make(bytes: Self.profileA)))
    }

    /// How identity is keyed today, without changing it: the MUID lives only in `MIDICIHeader`, and
    /// `MIDICapabilityCIAnswer.answered` keeps the `MIDICIDiscoveryInfo` (with its device identity) but no MUID. The
    /// negotiated result carries neither: it is keyed by nothing and describes one set of facts. Endpoint identity
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
        #expect(try Self.facts(Self.midi2Packets, answer: firstAnswer)
            != Self.facts(Self.midi2Packets, answer: secondAnswer))
        // Equal capabilities negotiate equally: the result names no device, so it cannot merge two of them.
        #expect(try Self.negotiate(Self.midi2Packets, answer: firstAnswer)
            == Self.negotiate(Self.midi2Packets, answer: secondAnswer))
    }
}
