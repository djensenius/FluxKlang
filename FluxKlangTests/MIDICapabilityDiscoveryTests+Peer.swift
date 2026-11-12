import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The peer identity, the MUID rule, the NAK, the function block MIDI 1.0 downgrade, the destination rule and the
/// transport (UMP group or legacy port) of Profile Replies in `MIDICapabilityDiscovery`.
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
        #expect(try discovery.collect(
            Self.profileReply(source: Self.otherRaw, enabled: 1, disabled: 0), on: .legacyPort)
            == .ignored(.otherMUID(other)))
        // The over-limit check is not reached for a message that is not the peer's.
        #expect(try discovery.collect(
            Self.profileReply(source: Self.otherRaw, enabled: 64, disabled: 1), on: .legacyPort)
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
        try silent.collect(Self.profileReply(enabled: 1, disabled: 0), on: .legacyPort)
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
        #expect(try discovery.collect(elsewhere, on: .legacyPort) == .ignored(.otherDestination(stranger)))
        #expect(discovery == afterReply)
        let broadcastProfiles = MIDICIProfileMessage.inquiryReply(
            try Self.header(destination: MIDICIMUID.broadcast.rawValue), enabled: [try Self.profile(1)], disabled: [])
        #expect(try discovery.collect(broadcastProfiles, on: .legacyPort) == .recorded)
    }

    @Test func withoutAHostMUIDNoDestinationIsChecked() throws {
        var discovery = Discovery()
        let misaddressed = MIDICIMessage.discoveryReply(
            try Self.header(destination: Self.otherRaw), try Self.info(), functionBlock: 0)
        #expect(try discovery.collect(misaddressed) == .recorded)
        #expect(discovery.host == nil)
    }

    // MARK: - Transport

    typealias Transport = MIDICapabilityCITransport

    static func group(_ value: UInt8) throws -> Transport {
        .group(try UMPGroup(value))
    }

    @Test func differentListsAtOneAddressOnTwoGroupsAreBothRecorded() throws {
        // Channel 0 and the group address (0x7E) are relative to the UMP group that carried the Reply.
        for device: UInt8 in [0x00, 0x7E] {
            var discovery = Discovery()
            try discovery.collect(Self.reply())
            let second = try Self.profileReply(device: device, enabled: 2, disabled: 0)
            let first = try Self.profileReply(device: device, enabled: 1, disabled: 1, from: 10)
            #expect(try discovery.collect(second, on: Self.group(1)) == .recorded, "device \(device)")
            #expect(try discovery.collect(first, on: Self.group(0)) == .recorded, "device \(device)")
            #expect(discovery.profileReplies.map(\.transport) == [try Self.group(0), try Self.group(1)])
            #expect(discovery.profileReplies.map(\.address.rawValue) == [device, device])
            let expected = try [10, 11, 0, 1].map(Self.profile)
            #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: expected))
        }
    }

    @Test func repliesAreOrderedByAddressKindThenTransportThenChannel() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let legacy = Transport.legacyPort
        // Arrival order is scrambled; each Reply carries one id of its own.
        let groups = try (UInt8(0)..<3).map(Self.group)
        let arrivals: [(UInt8, Transport)] = [
            (0x01, groups[0]), (0x00, groups[1]), (0x7E, groups[1]), (0x7E, legacy), (0x7F, groups[2]),
            (0x00, legacy), (0x00, groups[0])
        ]
        for ((device, transport), id) in zip(arrivals, [6, 7, 3, 2, 1, 4, 5]) {
            let message = try Self.profileReply(device: device, enabled: 1, disabled: 0, from: id)
            #expect(try discovery.collect(message, on: transport) == .recorded)
        }
        #expect(discovery.profileReplies.map(\.address.rawValue) == [0x7F, 0x7E, 0x7E, 0x00, 0x00, 0x01, 0x00])
        #expect(discovery.profileReplies.map(\.transport) == [
            groups[2], legacy, groups[1], legacy, groups[0], groups[0], groups[1]
        ])
        let expected = try (1...7).map(Self.profile)
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: expected))
    }

    @Test func oneGroupAndAddressRepeatsIdempotentlyAndRefusesADifferentList() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let groupOne = try Self.group(1)
        let channel = try SysExDeviceID(0x00)
        #expect(try discovery.collect(Self.profileReply(device: 0x00, enabled: 2, disabled: 1), on: groupOne)
            == .recorded)
        let once = discovery
        #expect(try discovery.collect(Self.profileReply(device: 0x00, enabled: 2, disabled: 1), on: groupOne)
            == .repeated)
        #expect(discovery == once)
        let changed = try Self.profileReply(device: 0x00, enabled: 1, disabled: 2)
        let refused = Self.refusal { () throws(Refusal) in try discovery.collect(changed, on: groupOne) }
        let muid = try Self.muid(Self.deviceRaw)
        #expect(refused == .conflictingProfileReply(muid, address: channel, transport: groupOne))
        #expect(discovery == once)
        // The same different list on another group is another address.
        #expect(try discovery.collect(changed, on: Self.group(2)) == .recorded)
    }

    @Test func aLegacyPortAndGroupZeroAreDistinctTransports() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let onGroup = try Self.profileReply(device: 0x00, enabled: 1, disabled: 0, from: 20)
        let onPort = try Self.profileReply(device: 0x00, enabled: 1, disabled: 0, from: 10)
        #expect(try discovery.collect(onGroup, on: Self.group(0)) == .recorded)
        #expect(try discovery.collect(onPort, on: .legacyPort) == .recorded)
        #expect(discovery.profileReplies.map(\.transport) == [.legacyPort, try Self.group(0)])
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: try [10, 20].map(Self.profile)))
    }

    @Test func theFunctionBlockIsOneAddressWhateverTheTransport() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let block = try Self.profileReply(device: 0x7F, enabled: 2, disabled: 0)
        #expect(try discovery.collect(block, on: Self.group(0)) == .recorded)
        let once = discovery
        // A block may span groups: the same Reply on another group or a legacy port is a repeat.
        #expect(try discovery.collect(block, on: Self.group(1)) == .repeated)
        #expect(try discovery.collect(block, on: .legacyPort) == .repeated)
        #expect(discovery == once)
        #expect(discovery.profileReplies.map(\.transport) == [try Self.group(0)])
        let changed = try Self.profileReply(device: 0x7F, enabled: 1, disabled: 0)
        let groupOne = try Self.group(1)
        let refused = Self.refusal { () throws(Refusal) in try discovery.collect(changed, on: groupOne) }
        let muid = try Self.muid(Self.deviceRaw)
        #expect(refused == .conflictingProfileReply(muid, address: .allCall, transport: groupOne))
        #expect(discovery == once)
    }

    @Test func theProfileCapCountsEveryCopyOnEveryGroup() throws {
        let limit = MIDICapabilityLimits.maximumProfiles
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        // The same 4 ids on channel 0 of all 16 groups: 64 stored copies, 4 advertised ids.
        for value in UInt8(0)..<16 {
            let message = try Self.profileReply(device: 0x00, enabled: 4, disabled: 0)
            #expect(try discovery.collect(message, on: Self.group(value)) == .recorded)
        }
        #expect(discovery.storedProfileCount == limit)
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: try (0..<4).map(Self.profile)))
        let before = discovery
        let more = try Self.profileReply(device: 0x00, enabled: 1, disabled: 0)
        let refused = Self.refusal { () throws(Refusal) in try discovery.collect(more, on: .legacyPort) }
        #expect(refused == .tooManyProfiles(count: limit + 1))
        #expect(discovery == before)
    }
}
