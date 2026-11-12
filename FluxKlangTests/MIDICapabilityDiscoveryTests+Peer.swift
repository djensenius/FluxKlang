import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The peer identity, the MUID rule, the NAK and the function block MIDI 1.0 downgrade of `MIDICapabilityDiscovery`.
extension MIDICapabilityDiscoveryTests {
    static let losses = MIDICapabilityResolver.midi2ToMIDI1Losses

    static func blockDowngrade(_ indices: [Int]) -> MIDICapabilityDowngrade {
        MIDICapabilityDowngrade(
            reason: .functionBlockMIDI1Only, lost: [], possibleTranslationLosses: losses,
            functionBlockIndices: indices)
    }

    /// A discovery of an endpoint with these blocks, answered by the device's Discovery Reply when `answered`.
    static func negotiated(
        _ blocks: [Block], midi2: Bool = true, answered: Bool = true
    ) throws -> MIDINegotiatedCapability {
        var discovery = Discovery()
        try discovery.collect(UMPStreamMessage.endpointInfo(endpoint(midi2: midi2, blocks: blocks.count)))
        for block in blocks {
            try discovery.collect(UMPStreamMessage.functionBlockInfo(block))
        }
        if answered { try discovery.collect(reply()) }
        return try MIDICapabilityResolver.negotiate(discovery.facts)
    }

    // MARK: - Peer and MUID

    @Test func thePeerKeepsTheMUIDTheCIIdentityAndTheStreamIdentity() throws {
        var discovery = Discovery()
        try discovery.collect(UMPStreamMessage.deviceIdentity(Self.streamIdentity()))
        try discovery.collect(Self.reply())
        let expected = MIDICapabilityPeer(
            muid: try Self.muid(Self.deviceRaw), ciIdentity: try Self.identity(), streamIdentity: Self.streamIdentity())
        #expect(discovery.peer == expected)
        // The facts carry no identity beyond the Discovery body: the peer sits next to them.
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: []))
    }

    @Test func thePeerHasNoStreamIdentityWhenNoneWasReceived() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let peer = discovery.peer
        #expect(peer.muid == (try Self.muid(Self.deviceRaw)))
        #expect(peer.ciIdentity == (try Self.identity()))
        #expect(peer.streamIdentity == nil)
    }

    @Test func messagesFromAnotherMUIDThanTheFirstDiscoveryReplyAreIgnored() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let before = discovery
        let other = try Self.muid(Self.otherRaw)
        // Another device answering the same broadcast Discovery, with another identity or the same one.
        for model: UInt16 in [0x0004, 0x0003] {
            let outcome = try discovery.collect(Self.reply(source: Self.otherRaw, model: model))
            #expect(outcome == .ignored(.otherMUID(other)))
        }
        #expect(try discovery.collect(Self.profileReply(source: Self.otherRaw, enabled: 1, disabled: 0))
            == .ignored(.otherMUID(other)))
        // The over-limit check is not reached for a message that is not the peer's.
        #expect(try discovery.collect(Self.profileReply(source: Self.otherRaw, enabled: 64, disabled: 1))
            == .ignored(.otherMUID(other)))
        #expect(discovery == before)
        #expect(discovery.peer.muid == (try Self.muid(Self.deviceRaw)))
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: []))
    }

    @Test func aDiscoveryReplyRepeatFromThePeerIsIdempotentAndADifferentOneIsRefused() throws {
        var discovery = Discovery()
        #expect(try discovery.collect(Self.reply()) == .recorded)
        #expect(try discovery.collect(Self.reply()) == .repeated)
        let before = discovery
        let device = try Self.muid(Self.deviceRaw)
        let changes = [
            try Self.reply(model: 0x0004), try Self.reply(functionBlock: 1), try Self.reply(functionBlock: nil)
        ]
        for changed in changes {
            let refused = Self.refusal { () throws(Refusal) in try discovery.collect(changed) }
            #expect(refused == .conflictingDiscoveryReply(device))
            #expect(discovery == before)
        }
    }

    @Test func aDiscoveryReplyAwayFromTheFunctionBlockIsRefusedFirstOrNot() throws {
        let channel5 = try SysExDeviceID(0x05)
        let stray = MIDICIMessage.discoveryReply(try Self.header(device: 0x05), try Self.info(), functionBlock: 0)
        var discovery = Discovery()
        // First: refused, so it never becomes the peer.
        let first = Self.refusal { () throws(Refusal) in try discovery.collect(stray) }
        #expect(first == .discoveryReplyNotAtFunctionBlock(device: channel5))
        #expect(discovery == Discovery())
        #expect(discovery.peer.muid == nil)
        // The spec-correct reply at 0x7F then fixes the peer.
        #expect(try discovery.collect(Self.reply()) == .recorded)
        #expect(discovery.peer.muid == (try Self.muid(Self.deviceRaw)))
        // Later from the peer: still refused, state unchanged.
        let before = discovery
        let later = Self.refusal { () throws(Refusal) in try discovery.collect(stray) }
        #expect(later == .discoveryReplyNotAtFunctionBlock(device: channel5))
        #expect(discovery == before)
        // Later from another MUID: ignored before the address is looked at, like any other MUID's message.
        let otherStray = MIDICIMessage.discoveryReply(
            try Self.header(source: Self.otherRaw, device: 0x05), try Self.info(), functionBlock: 0)
        #expect(try discovery.collect(otherStray) == .ignored(.otherMUID(try Self.muid(Self.otherRaw))))
        #expect(discovery == before)
    }

    // MARK: - NAK

    @Test func aNAKGivesMissingLikeNoReply() throws {
        let report = try MIDICIStatusReport.make(
            originalSubID: 0x70, statusCode: 0, statusData: 0, details: [0, 0, 0, 0, 0], text: "")
        let naks: [MIDICIMessage] = [.nak(try Self.header(), report), .nak(try Self.header(format: .ci11), nil)]
        for nak in naks {
            var discovery = Discovery()
            try discovery.collect(UMPStreamMessage.endpointInfo(Self.endpoint()))
            let silent = discovery
            #expect(try discovery.collect(nak) == .ignored(.notCollected))
            #expect(discovery == silent)
            #expect(discovery.facts.ciAnswer == .missing)
            #expect(discovery.peer.muid == nil)
            let result = try MIDICapabilityResolver.negotiate(discovery.facts)
            #expect(result.level == .legacyByteStream)
            #expect(result == (try MIDICapabilityResolver.negotiate(silent.facts)))
            // A NAK never removes a Discovery Reply already collected.
            try discovery.collect(Self.reply())
            let answered = discovery
            #expect(try discovery.collect(nak) == .ignored(.notCollected))
            #expect(discovery == answered)
        }
    }

    // MARK: - Function block MIDI 1.0 mode

    @Test func anUnrestrictedMIDI1BlockOnAMIDI2EndpointRecordsTheDowngrade() throws {
        let result = try Self.negotiated([Self.block(0), Self.block(1, mode: .unrestricted)])
        #expect(result.level == .umpMIDI2)
        #expect(result.features.contains(.midi2Protocol))
        #expect(result.downgrades == [Self.blockDowngrade([1])])
    }

    @Test func aRestrictedMIDI1BlockOnAMIDI2EndpointRecordsTheDowngrade() throws {
        let result = try Self.negotiated([Self.block(0, mode: .restricted), Self.block(1)])
        #expect(result.level == .umpMIDI2)
        #expect(result.downgrades == [Self.blockDowngrade([0])])
    }

    @Test func theDowngradeNamesEveryActiveMIDI1BlockAscending() throws {
        let blocks = [
            Self.block(3, mode: .restricted), Self.block(0, mode: .unrestricted), Self.block(2),
            Self.block(1, mode: .unrestricted, active: false)
        ]
        let result = try Self.negotiated(blocks)
        #expect(result.level == .umpMIDI2)
        let record = try #require(result.downgrades.first)
        #expect(result.downgrades.count == 1)
        #expect(record == Self.blockDowngrade([0, 3]))
    }

    @Test func notMIDI1BlocksRecordNoDowngrade() throws {
        let result = try Self.negotiated([Self.block(0), Self.block(1)])
        #expect(result.level == .umpMIDI2)
        #expect(result.downgrades.isEmpty)
    }

    @Test func anInactiveMIDI1BlockRecordsNoDowngrade() throws {
        let result = try Self.negotiated([Self.block(0), Self.block(1, mode: .unrestricted, active: false)])
        #expect(result.level == .umpMIDI2)
        #expect(result.downgrades.isEmpty)
    }

    @Test func aMIDI1BlockAtTheUMPMIDI1LevelRecordsOnlyEndpointLacksMIDI2() throws {
        let result = try Self.negotiated([Self.block(0, mode: .unrestricted)], midi2: false)
        #expect(result.level == .umpMIDI1)
        let reasons = result.downgrades.map(\.reason)
        #expect(reasons == [.endpointLacksMIDI2])
        let record = try #require(result.downgrades.first)
        #expect(record.functionBlockIndices.isEmpty)
    }

    @Test func aMIDI1BlockWithoutACIAnswerRecordsNoBlockDowngrade() throws {
        let result = try Self.negotiated([Self.block(0, mode: .unrestricted)], answered: false)
        #expect(result.level == .legacyByteStream)
        #expect(result.downgrades.map(\.reason) == [.ciAnswerMissing])
    }

    @Test func everyOtherReasonCarriesNoBlockIndices() throws {
        let missing = try Self.negotiated([Self.block(0, mode: .unrestricted)], midi2: false, answered: false)
        #expect(missing.downgrades.map(\.reason) == [.ciAnswerMissing, .endpointLacksMIDI2])
        #expect(missing.downgrades.allSatisfy { $0.functionBlockIndices.isEmpty })

        // `umpMIDI2` with a MIDI 1.0 block and profiles under a category without the profile bit: only the block
        // record names blocks.
        var silent = Discovery()
        try silent.collect(UMPStreamMessage.endpointInfo(Self.endpoint(blocks: 1)))
        try silent.collect(UMPStreamMessage.functionBlockInfo(Self.block(0, mode: .restricted)))
        try silent.collect(MIDICIMessage.discoveryReply(
            try Self.header(), try Self.info(category: 0x0A), functionBlock: 0))
        try silent.collect(Self.profileReply(enabled: 1, disabled: 0))
        let quiet = try MIDICapabilityResolver.negotiate(silent.facts)
        #expect(quiet.level == .umpMIDI2)
        #expect(quiet.downgrades == [
            Self.blockDowngrade([0]),
            MIDICapabilityDowngrade(reason: .profilesNotAdvertised, lost: [.profileConfiguration],
                                    possibleTranslationLosses: [])
        ])

        // No endpoint, and an endpoint with no protocol: neither names a block.
        var bare = Discovery()
        try bare.collect(Self.reply())
        var noProtocol = bare
        try noProtocol.collect(UMPStreamMessage.endpointInfo(Self.endpoint(midi1: false, midi2: false)))
        let reasons: [(Discovery, MIDICapabilityDowngradeReason)] = [
            (bare, .noUMPEndpoint), (noProtocol, .endpointSupportsNoProtocol)
        ]
        for (discovery, reason) in reasons {
            let result = try MIDICapabilityResolver.negotiate(discovery.facts)
            #expect(result.level == .legacyByteStream)
            let record = try #require(result.downgrades.first)
            #expect(result.downgrades.count == 1)
            #expect(record.reason == reason)
            #expect(record.functionBlockIndices.isEmpty)
        }
    }

    // MARK: - Destination

    @Test func withAHostMUIDRepliesAddressedElsewhereAreIgnored() throws {
        let host = try Self.muid(Self.hostRaw)
        let stranger = try Self.muid(Self.otherRaw)
        var discovery = Discovery(host: host)
        let misaddressed = MIDICIMessage.discoveryReply(
            try Self.header(destination: Self.otherRaw), try Self.info(), functionBlock: 0)
        #expect(try discovery.collect(misaddressed) == .ignored(.otherDestination(stranger)))
        #expect(discovery == Discovery(host: host))
        // To the host and to broadcast are both collected.
        #expect(try discovery.collect(Self.reply()) == .recorded)
        let broadcastReply = MIDICIMessage.discoveryReply(
            try Self.header(destination: MIDICIMUID.broadcast.rawValue), try Self.info(), functionBlock: 0)
        let afterReply = discovery
        #expect(try discovery.collect(broadcastReply) == .repeated)
        let elsewhere = MIDICIProfileMessage.inquiryReply(
            try Self.header(destination: Self.otherRaw), enabled: [try Self.profile(1)], disabled: [])
        #expect(try discovery.collect(elsewhere) == .ignored(.otherDestination(stranger)))
        #expect(discovery == afterReply)
        let broadcastProfiles = MIDICIProfileMessage.inquiryReply(
            try Self.header(destination: MIDICIMUID.broadcast.rawValue), enabled: [try Self.profile(1)], disabled: [])
        #expect(try discovery.collect(broadcastProfiles) == .recorded)
    }

    @Test func withoutAHostMUIDNoDestinationIsChecked() throws {
        var discovery = Discovery()
        let misaddressed = MIDICIMessage.discoveryReply(
            try Self.header(destination: Self.otherRaw), try Self.info(), functionBlock: 0)
        #expect(try discovery.collect(misaddressed) == .recorded)
        #expect(discovery.host == nil)
    }
}
