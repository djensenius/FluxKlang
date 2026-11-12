import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of `MIDICapabilityDiscovery`, the production adapter from decoded UMP Stream and MIDI-CI messages to
/// `MIDICapabilityFacts` (#83, slice UCA1, #572). This file covers the collection rules of the UMP Stream state and of
/// the profile Reply; `+Peer` covers the peer identity, the MUID rule, the NAK and the function block MIDI 1.0
/// downgrade. Every message is built as a value, with no decoder in between.
#if os(macOS)
@Suite("MIDI capability discovery", .productionAccessAudit)
#else
@Suite("MIDI capability discovery")
#endif
struct MIDICapabilityDiscoveryTests {
    typealias Discovery = MIDICapabilityDiscovery
    typealias Block = UMPStreamFunctionBlockInfo
    typealias Refusal = MIDICapabilityDiscoveryRefusal

    // MARK: - Fixtures

    static let hostRaw: UInt32 = 0x0123_4567
    static let deviceRaw: UInt32 = 0x0765_4321
    static let otherRaw: UInt32 = 0x0055_5555

    static func muid(_ raw: UInt32) throws -> MIDICIMUID {
        try MIDICIMUID.make(raw)
    }

    /// A header from `source` to `destination` at address `device` (0x7F: the function block or whole port).
    static func header(
        source: UInt32 = deviceRaw, format: MIDICIFormat = .ci12, device: UInt8 = 0x7F, destination: UInt32 = hostRaw
    ) throws -> MIDICIHeader {
        MIDICIHeader(
            device: try SysExDeviceID(device), format: format, source: try muid(source),
            destination: try muid(destination))
    }

    static func identity(model: UInt16 = 0x0003) throws -> MIDICIDeviceIdentity {
        try MIDICIDeviceIdentity.make(
            manufacturer: [0x00, 0x21, 0x09], family: 0x0102, model: model, softwareRevision: [1, 0, 0, 0])
    }

    static func info(model: UInt16 = 0x0003, category: UInt8 = 0x0E) throws -> MIDICIDiscoveryInfo {
        try MIDICIDiscoveryInfo.make(
            identity: try identity(model: model), capabilityCategory: category, maximumSysExSize: 512,
            outputPathID: 0)
    }

    static func reply(
        source: UInt32 = deviceRaw, model: UInt16 = 0x0003, functionBlock: UInt8? = 0
    ) throws -> MIDICIMessage {
        .discoveryReply(try header(source: source), try info(model: model), functionBlock: functionBlock)
    }

    /// Profile `number` is `7E 00 hi lo 01`, `number` split 7 bits per byte: distinct and 7-bit for 0..<16384.
    static func profile(_ number: Int) throws -> MIDICapabilityProfileID {
        try MIDICapabilityProfileID.make(bytes: [0x7E, 0x00, UInt8(number >> 7), UInt8(number & 0x7F), 0x01])
    }

    /// A Reply at `device` with ids `start..<start + enabled` enabled and the next `disabled` ids disabled.
    static func profileReply(
        source: UInt32 = deviceRaw, device: UInt8 = 0x7F, enabled: Int, disabled: Int, from start: Int = 0
    ) throws -> MIDICIProfileMessage {
        let middle = start + enabled
        let enabledIDs = try (start..<middle).map(profile)
        let disabledIDs = try (middle..<(middle + disabled)).map(profile)
        return .inquiryReply(try header(source: source, device: device), enabled: enabledIDs, disabled: disabledIDs)
    }

    static func endpoint(midi1: Bool = true, midi2: Bool = true, blocks: Int = 0) -> UMPStreamEndpointInfo {
        UMPStreamEndpointInfo(
            version: UMPStreamVersion(major: 1, minor: 1), hasStaticFunctionBlocks: true, functionBlockCount: blocks,
            supportsMIDI1: midi1, supportsMIDI2: midi2, receivesJitterReduction: false, transmitsJitterReduction: false)
    }

    /// A one-group block on group `index` (no overlap for indices 0 to 15).
    static func block(
        _ index: Int, mode: UMPStreamMIDI1Mode = .notMIDI1, active: Bool = true, group: Int? = nil
    ) -> Block {
        Block(
            index: index, isActive: active, uiHint: .both, midi1Mode: mode, direction: .bidirectional,
            firstGroup: group ?? index, groupCount: 1, midiCIVersion: 2, maximumSysEx8Streams: 0)
    }

    static func streamIdentity(model: UInt8 = 0x03) -> UMPStreamDeviceIdentity {
        UMPStreamDeviceIdentity(
            manufacturer1: 0x00, manufacturer2: 0x21, manufacturer3: 0x09, familyLSB: 0x02, familyMSB: 0x02,
            modelLSB: model, modelMSB: 0x00, revision1: 1, revision2: 0, revision3: 0, revision4: 0)
    }

    /// The refusal of one `collect`, or nil when it was accepted.
    static func refusal(_ body: () throws(Refusal) -> Void) -> Refusal? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Empty

    @Test func anEmptyDiscoveryHasMissingFactsAndNoPeer() {
        let discovery = Discovery()
        #expect(discovery.facts == MIDICapabilityFacts(endpoint: nil, functionBlocks: [], ciAnswer: .missing))
        #expect(discovery.peer == MIDICapabilityPeer(muid: nil, ciIdentity: nil, streamIdentity: nil))
    }

    // MARK: - Endpoint Info and Device Identity

    @Test func anIdenticalEndpointInfoRepeatIsIdempotent() throws {
        var discovery = Discovery()
        #expect(try discovery.collect(UMPStreamMessage.endpointInfo(Self.endpoint())) == .recorded)
        let once = discovery
        #expect(try discovery.collect(UMPStreamMessage.endpointInfo(Self.endpoint())) == .repeated)
        #expect(discovery == once)
        #expect(discovery.facts.endpoint == Self.endpoint())
    }

    @Test func aDifferentEndpointInfoIsRefusedAndTheFirstIsKept() throws {
        var discovery = Discovery()
        try discovery.collect(UMPStreamMessage.endpointInfo(Self.endpoint()))
        let before = discovery
        let other = Self.endpoint(midi2: false)
        let refused = Self.refusal { () throws(Refusal) in
            try discovery.collect(UMPStreamMessage.endpointInfo(other))
        }
        #expect(refused == .conflictingEndpointInfo(kept: Self.endpoint(), received: other))
        #expect(discovery == before)
        #expect(discovery.facts.endpoint == Self.endpoint())
    }

    @Test func theStreamDeviceIdentityIsIdempotentOnRepeatAndRefusedOnConflict() throws {
        var discovery = Discovery()
        #expect(try discovery.collect(UMPStreamMessage.deviceIdentity(Self.streamIdentity())) == .recorded)
        #expect(try discovery.collect(UMPStreamMessage.deviceIdentity(Self.streamIdentity())) == .repeated)
        let before = discovery
        let other = Self.streamIdentity(model: 0x04)
        let refused = Self.refusal { () throws(Refusal) in
            try discovery.collect(UMPStreamMessage.deviceIdentity(other))
        }
        #expect(refused == .conflictingDeviceIdentity(kept: Self.streamIdentity(), received: other))
        #expect(discovery == before)
        #expect(discovery.peer.streamIdentity == Self.streamIdentity())
    }

    // MARK: - Function blocks

    @Test func blocksAreKeyedByIndexListedAscendingAndAnIdenticalRepeatIsIdempotent() throws {
        var discovery = Discovery()
        for index in [2, 0, 1] {
            #expect(try discovery.collect(UMPStreamMessage.functionBlockInfo(Self.block(index))) == .recorded)
        }
        let once = discovery
        #expect(try discovery.collect(UMPStreamMessage.functionBlockInfo(Self.block(0))) == .repeated)
        #expect(discovery == once)
        #expect(discovery.facts.functionBlocks == [Self.block(0), Self.block(1), Self.block(2)])
    }

    @Test func aDifferentBlockWithAKnownIndexIsRefused() throws {
        var discovery = Discovery()
        try discovery.collect(UMPStreamMessage.functionBlockInfo(Self.block(3)))
        let before = discovery
        for other in [Self.block(3, group: 4), Self.block(3, mode: .restricted), Self.block(3, active: false)] {
            let refused = Self.refusal { () throws(Refusal) in
                try discovery.collect(UMPStreamMessage.functionBlockInfo(other))
            }
            #expect(refused == .conflictingFunctionBlock(index: 3))
            #expect(discovery == before)
        }
    }

    @Test func blocksAreBoundedAtTheLimitAndOneMoreIsRefused() throws {
        let limit = MIDICapabilityLimits.maximumFunctionBlocks
        #expect(limit == 32)
        var discovery = Discovery()
        for index in 0..<limit {
            #expect(try discovery.collect(UMPStreamMessage.functionBlockInfo(Self.block(index, group: 0))) == .recorded)
        }
        // A repeat at the limit is still idempotent, not a new block.
        #expect(try discovery.collect(UMPStreamMessage.functionBlockInfo(Self.block(5, group: 0))) == .repeated)
        let before = discovery
        let refused = Self.refusal { () throws(Refusal) in
            try discovery.collect(UMPStreamMessage.functionBlockInfo(Self.block(limit, group: 0)))
        }
        #expect(refused == .tooManyFunctionBlocks(count: limit + 1))
        #expect(discovery == before)
        #expect(discovery.facts.functionBlocks.count == limit)
        #expect(discovery.facts.functionBlocks.map(\.index) == Array(0..<limit))
    }

    // MARK: - Profile Reply

    @Test func theProfileReplyCombinesEnabledThenDisabledInReplyOrder() throws {
        let first = try Self.profile(9)
        let second = try Self.profile(2)
        let third = try Self.profile(5)
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let reply = MIDICIProfileMessage.inquiryReply(try Self.header(), enabled: [first, second], disabled: [third])
        #expect(try discovery.collect(reply, on: .legacyPort) == .recorded)
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: [first, second, third]))
        // The resolver then sorts by value.
        let result = try MIDICapabilityResolver.negotiate(discovery.facts)
        #expect(result.profiles == [second, third, first])
    }

    @Test func theCombinedProfileCountIsAcceptedAt64AndRefusedAt65() throws {
        let limit = MIDICapabilityLimits.maximumProfiles
        #expect(limit == 64)
        for (enabled, disabled) in [(limit, 0), (0, limit), (limit / 2, limit / 2), (1, limit - 1)] {
            var discovery = Discovery()
            try discovery.collect(Self.reply())
            #expect(try discovery.collect(
                Self.profileReply(enabled: enabled, disabled: disabled), on: .legacyPort) == .recorded)
            let result = try MIDICapabilityResolver.negotiate(discovery.facts)
            #expect(result.profiles.count == limit, "\(enabled) + \(disabled)")
        }
        // Each list is within the decoder's per-list bound; only the combined count is over.
        for (enabled, disabled) in [(limit, 1), (1, limit), (limit / 2 + 1, limit / 2)] {
            var discovery = Discovery()
            try discovery.collect(Self.reply())
            let before = discovery
            let message = try Self.profileReply(enabled: enabled, disabled: disabled)
            let refused = Self.refusal { () throws(Refusal) in try discovery.collect(message, on: .legacyPort) }
            #expect(refused == .tooManyProfiles(count: limit + 1), "\(enabled) + \(disabled)")
            #expect(discovery == before)
            #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: []))
        }
    }

    @Test func aProfileReplyRepeatIsIdempotentAndADifferentOneIsRefused() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        #expect(try discovery.collect(Self.profileReply(enabled: 2, disabled: 1), on: .legacyPort) == .recorded)
        let once = discovery
        #expect(try discovery.collect(Self.profileReply(enabled: 2, disabled: 1), on: .legacyPort) == .repeated)
        #expect(discovery == once)
        // The same ids split differently, other ids, one more id, or the same ids in another order: a different reply.
        let changes = [
            try Self.profileReply(enabled: 1, disabled: 2),
            try Self.profileReply(enabled: 2, disabled: 2),
            MIDICIProfileMessage.inquiryReply(
                try Self.header(), enabled: [try Self.profile(1), try Self.profile(0)], disabled: [try Self.profile(2)])
        ]
        for changed in changes {
            let refused = Self.refusal { () throws(Refusal) in try discovery.collect(changed, on: .legacyPort) }
            let muid = try Self.muid(Self.deviceRaw)
            #expect(refused == .conflictingProfileReply(muid, address: .allCall, transport: .legacyPort))
            #expect(discovery == once)
        }
    }

    @Test func repliesAtDifferentAddressesAreAllRecordedAndUnitedInAddressOrder() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        // Arrival order: channel 2, function block, channel 0, group. Ids 0-1 on channel 2, 10-12 on the function
        // block, 20 on channel 0, 30 on the group.
        let arrivals: [(UInt8, MIDICIProfileMessage)] = [
            (0x02, try Self.profileReply(device: 0x02, enabled: 1, disabled: 1)),
            (0x7F, try Self.profileReply(device: 0x7F, enabled: 2, disabled: 1, from: 10)),
            (0x00, try Self.profileReply(device: 0x00, enabled: 0, disabled: 1, from: 20)),
            (0x7E, try Self.profileReply(device: 0x7E, enabled: 1, disabled: 0, from: 30))
        ]
        for (device, message) in arrivals {
            #expect(try discovery.collect(message, on: .legacyPort) == .recorded, "address \(device)")
        }
        #expect(discovery.profileReplies.map(\.address.rawValue) == [0x7F, 0x7E, 0x00, 0x02])
        let expected = try [10, 11, 12, 30, 20, 0, 1].map(Self.profile)
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: expected))
        #expect(try MIDICapabilityResolver.negotiate(discovery.facts).profiles.count == expected.count)
    }

    @Test func anIDOnSeveralAddressesIsAdvertisedOnceFirstOccurrenceWins() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let shared = try Self.profile(1)
        let only = try Self.profile(2)
        // Disabled on channel 0, enabled on the function block: advertised once, at the function block's place.
        let channel = MIDICIProfileMessage.inquiryReply(
            try Self.header(device: 0x00), enabled: [only], disabled: [shared])
        let block = MIDICIProfileMessage.inquiryReply(try Self.header(), enabled: [shared], disabled: [])
        try discovery.collect(channel, on: .legacyPort)
        try discovery.collect(block, on: .legacyPort)
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: [shared, only]))
        #expect(try MIDICapabilityResolver.negotiate(discovery.facts).profiles == [shared, only])
    }

    @Test func aReplyListingAnIDTwiceIsRefusedBeforeAnythingIsStored() throws {
        let twice = try Self.profile(1)
        let other = try Self.profile(2)
        // One address: the id in both lists, or twice in one list.
        let alone: [([MIDICapabilityProfileID], [MIDICapabilityProfileID])] = [
            ([twice], [twice]), ([twice, other, twice], []), ([], [other, twice, twice])
        ]
        for (enabled, disabled) in alone {
            var discovery = Discovery()
            try discovery.collect(Self.reply())
            let before = discovery
            let reply = MIDICIProfileMessage.inquiryReply(try Self.header(), enabled: enabled, disabled: disabled)
            let refused = Self.refusal { () throws(Refusal) in try discovery.collect(reply, on: .legacyPort) }
            #expect(refused == .duplicateProfileInReply(device: .allCall, transport: .legacyPort))
            #expect(discovery == before)
        }
        // Two addresses: the cross-address union would drop both copies at channel 0, so the Reply is refused rather
        // than hidden.
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        try discovery.collect(
            MIDICIProfileMessage.inquiryReply(try Self.header(), enabled: [twice], disabled: []), on: .legacyPort)
        let before = discovery
        let channel = try SysExDeviceID(0x00)
        let malformed = MIDICIProfileMessage.inquiryReply(
            try Self.header(device: 0x00), enabled: [twice], disabled: [twice])
        let refused = Self.refusal { () throws(Refusal) in try discovery.collect(malformed, on: .legacyPort) }
        #expect(refused == .duplicateProfileInReply(device: channel, transport: .legacyPort))
        #expect(discovery == before)
        #expect(discovery.facts.ciAnswer == .answered(try Self.info(), profiles: [twice]))
    }

    @Test func eachAddressHasItsOwnRepeatAndConflictRule() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        try discovery.collect(Self.profileReply(device: 0x7F, enabled: 1, disabled: 1), on: .legacyPort)
        #expect(try discovery.collect(
            Self.profileReply(device: 0x03, enabled: 2, disabled: 0, from: 5), on: .legacyPort) == .recorded)
        let both = discovery
        #expect(try discovery.collect(
            Self.profileReply(device: 0x03, enabled: 2, disabled: 0, from: 5), on: .legacyPort) == .repeated)
        #expect(discovery == both)
        let device = try Self.muid(Self.deviceRaw)
        let changes: [(MIDICIProfileMessage, MIDICapabilityDiscoveryRefusal)] = [
            (try Self.profileReply(device: 0x03, enabled: 1, disabled: 1, from: 5),
             .conflictingProfileReply(device, address: try SysExDeviceID(0x03), transport: .legacyPort)),
            (try Self.profileReply(device: 0x7F, enabled: 0, disabled: 0),
             .conflictingProfileReply(device, address: .allCall, transport: .legacyPort))
        ]
        for (message, expected) in changes {
            let refused = Self.refusal { () throws(Refusal) in try discovery.collect(message, on: .legacyPort) }
            #expect(refused == expected)
            #expect(discovery == both)
        }
    }

    @Test func theProfileTotalOverEveryAddressIsBoundedAt64() throws {
        let limit = MIDICapabilityLimits.maximumProfiles
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        try discovery.collect(Self.profileReply(device: 0x7F, enabled: 30, disabled: 10), on: .legacyPort)
        let channel = try Self.profileReply(device: 0x00, enabled: 20, disabled: 3, from: 100)
        #expect(try discovery.collect(channel, on: .legacyPort) == .recorded)
        #expect(discovery.storedProfileCount == limit - 1)
        let before = discovery
        // A new address that would bring the total to 65, even with an id already stored elsewhere, is refused.
        for message in [
            try Self.profileReply(device: 0x01, enabled: 1, disabled: 1, from: 200),
            try Self.profileReply(device: 0x7E, enabled: 2, disabled: 0)
        ] {
            let refused = Self.refusal { () throws(Refusal) in try discovery.collect(message, on: .legacyPort) }
            #expect(refused == .tooManyProfiles(count: limit + 1))
            #expect(discovery == before)
        }
        // One more id fills the bound exactly.
        #expect(try discovery.collect(
            Self.profileReply(device: 0x01, enabled: 1, disabled: 0, from: 200), on: .legacyPort) == .recorded)
        #expect(discovery.storedProfileCount == limit)
        #expect(try MIDICapabilityResolver.negotiate(discovery.facts).profiles.count == limit)
    }

    @Test func aProfileReplyBeforeAnyDiscoveryReplyIsIgnored() throws {
        var discovery = Discovery()
        #expect(try discovery.collect(
            Self.profileReply(enabled: 1, disabled: 0), on: .legacyPort) == .ignored(.beforeDiscoveryReply))
        #expect(discovery == Discovery())
        #expect(discovery.facts.ciAnswer == .missing)
    }

    @Test func messagesWithoutACapabilityFactAreNotCollected() throws {
        var discovery = Discovery()
        try discovery.collect(Self.reply())
        let before = discovery
        let streamMessages: [UMPStreamMessage] = [
            .endpointName(UMPStreamString("Synth")), .functionBlockName(index: 0, name: UMPStreamString("Main")),
            .startOfClip, .endOfClip
        ]
        for message in streamMessages {
            #expect(try discovery.collect(message) == .ignored(.notCollected), "\(message)")
        }
        let report = try MIDICIStatusReport.make(
            originalSubID: 0x70, statusCode: 0, statusData: 0, details: [0, 0, 0, 0, 0], text: "")
        let ciMessages: [MIDICIMessage] = [
            .discovery(try Self.header(source: Self.hostRaw), try Self.info()), .ack(try Self.header(), report)
        ]
        for message in ciMessages {
            #expect(try discovery.collect(message) == .ignored(.notCollected), "\(message)")
        }
        let toDevice = try Self.header(source: Self.hostRaw, destination: Self.deviceRaw)
        let profileMessages: [MIDICIProfileMessage] = [
            .inquiry(try Self.header(source: Self.hostRaw)),
            .setProfileOn(toDevice, profile: try Self.profile(1), channels: 1),
            .setProfileOff(toDevice, profile: try Self.profile(1)),
            .addedReport(try Self.header(), profile: try Self.profile(1))
        ]
        for message in profileMessages {
            #expect(try discovery.collect(message, on: .legacyPort) == .ignored(.notCollected), "\(message)")
        }
        #expect(discovery == before)
    }
}
