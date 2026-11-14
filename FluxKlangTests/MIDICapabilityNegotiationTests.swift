import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of the MIDI capability negotiation (#83, slice CAP1): fixtures, the level rule, the granted features and the
/// profile identifier factory. The topic files extend this suite with the downgrade records, the refusals and the
/// input-order tests.
@Suite(.productionAccessAudit)
struct MIDICapabilityNegotiationTests {
    typealias Block = UMPStreamFunctionBlockInfo
    typealias Facts = MIDICapabilityFacts
    typealias CIAnswer = MIDICapabilityCIAnswer
    typealias Level = MIDICapabilityLevel
    typealias Feature = MIDICapabilityFeature

    // MARK: - Fixtures

    /// Capability category 0b1110: the profile configuration bit (0x04) is set.
    static let announcingCategory: UInt8 = 0x0E
    /// Capability category 0b1010: the profile configuration bit (0x04) is clear.
    static let silentCategory: UInt8 = 0x0A

    enum Kind: CaseIterable {
        case absent
        case noProtocol
        case midi1Only
        case midi2Only
        case midi1And2
    }

    static func identity() throws -> MIDICIDeviceIdentity {
        try MIDICIDeviceIdentity.make(
            manufacturer: [0x00, 0x20, 0x29], family: 0x0101, model: 0x0203, softwareRevision: [5, 6, 7, 8])
    }

    static func info(category: UInt8) throws -> MIDICIDiscoveryInfo {
        try MIDICIDiscoveryInfo.make(
            identity: try identity(), capabilityCategory: category, maximumSysExSize: 4_096, outputPathID: nil)
    }

    static func profile(_ first: UInt8, _ second: UInt8 = 0) throws -> MIDICapabilityProfileID {
        try MIDICapabilityProfileID.make(bytes: [first, second, 0, 0, 0])
    }

    static func answer(
        category: UInt8 = announcingCategory, profiles: [MIDICapabilityProfileID] = []
    ) throws -> MIDICapabilityCIAnswer {
        .answered(try info(category: category), profiles: profiles)
    }

    static func endpoint(
        midi1: Bool, midi2: Bool, receives: Bool = false, transmits: Bool = false, declared: Int = 0
    ) -> UMPStreamEndpointInfo {
        UMPStreamEndpointInfo(
            version: UMPStreamVersion(major: 1, minor: 1), hasStaticFunctionBlocks: true, functionBlockCount: declared,
            supportsMIDI1: midi1, supportsMIDI2: midi2, receivesJitterReduction: receives,
            transmitsJitterReduction: transmits)
    }

    static func endpoint(of kind: Kind, declared: Int = 0) -> UMPStreamEndpointInfo? {
        switch kind {
        case .absent: return nil
        case .noProtocol: return endpoint(midi1: false, midi2: false, declared: declared)
        case .midi1Only: return endpoint(midi1: true, midi2: false, declared: declared)
        case .midi2Only: return endpoint(midi1: false, midi2: true, declared: declared)
        case .midi1And2: return endpoint(midi1: true, midi2: true, declared: declared)
        }
    }

    /// A MIDI 2.0 block (`notMIDI1`), so a MIDI 2.0 endpoint records no `functionBlockMIDI1Only` downgrade for it.
    static func block(_ index: Int, first: Int, count: Int = 1, active: Bool = true) -> Block {
        Block(
            index: index, isActive: active, uiHint: .both, midi1Mode: .notMIDI1, direction: .bidirectional,
            firstGroup: first, groupCount: count, midiCIVersion: 2, maximumSysEx8Streams: 1)
    }

    /// A one-group block whose first group is its index (valid for indices 0 to 15, and never overlapping another).
    static func tile(_ index: Int, active: Bool = true) -> Block {
        block(index, first: index, count: 1, active: active)
    }

    static func tiles(_ count: Int) -> [Block] {
        (0..<count).map { tile($0) }
    }

    static func facts(_ endpoint: UMPStreamEndpointInfo?, _ blocks: [Block], _ answered: CIAnswer) -> Facts {
        Facts(endpoint: endpoint, functionBlocks: blocks, ciAnswer: answered)
    }

    /// A MIDI 1.0 and 2.0 endpoint that declares `blocks.count` blocks, with a Discovery answer.
    static func full(
        blocks: [Block] = [], category: UInt8 = announcingCategory, profiles: [MIDICapabilityProfileID] = []
    ) throws -> Facts {
        facts(
            endpoint(midi1: true, midi2: true, receives: true, declared: blocks.count), blocks,
            try answer(category: category, profiles: profiles))
    }

    static func negotiated(_ facts: Facts) throws -> MIDINegotiatedCapability {
        try MIDICapabilityResolver.negotiate(facts)
    }

    static func refusal(_ facts: Facts) -> MIDICapabilityRefusal? {
        do {
            _ = try MIDICapabilityResolver.negotiate(facts)
            return nil
        } catch {
            return error
        }
    }

    static func profileRefusal(_ bytes: [UInt8]) -> MIDICapabilityRefusal? {
        do {
            _ = try MIDICapabilityProfileID.make(bytes: bytes)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The level rule

    @Test func everyEndpointKindWithAndWithoutAnAnswerGivesTheExpectedLevel() throws {
        let legacy: Level = .legacyByteStream
        let midi1: Level = .umpMIDI1
        let midi2: Level = .umpMIDI2
        let withAnswer: [Kind: Level] = [
            .absent: legacy, .noProtocol: legacy, .midi1Only: midi1, .midi2Only: midi2, .midi1And2: midi2
        ]
        for kind in Kind.allCases {
            let expectedWith: Level = try #require(withAnswer[kind])
            let answered = Self.facts(Self.endpoint(of: kind), [], try Self.answer())
            let missing = Self.facts(Self.endpoint(of: kind), [], .missing)
            let resultWith = try Self.negotiated(answered)
            let resultWithout = try Self.negotiated(missing)
            #expect(resultWith.level == expectedWith, "\(kind) answered")
            #expect(resultWithout.level == legacy, "\(kind) missing")
        }
    }

    @Test func aMIDI2EndpointWithoutAnAnswerStaysOnTheLegacyByteStream() throws {
        let result = try Self.negotiated(Self.facts(Self.endpoint(midi1: true, midi2: true), [], .missing))
        let legacy: Level = .legacyByteStream
        #expect(result.level == legacy)
        let expectedFeatures: [Feature] = []
        #expect(result.features == expectedFeatures)
    }

    @Test func replacingTheAnswerDroppingTheEndpointOrClearingMIDI2NeverRaisesTheRank() throws {
        var checked = 0
        for kind in Kind.allCases {
            let counts = kind == .absent ? [0] : [0, 2]
            for blockCount in counts {
                let blocks = Self.tiles(blockCount)
                let reply = try Self.answer()
                let base = Self.facts(Self.endpoint(of: kind, declared: blockCount), blocks, reply)
                var cleared = base.endpoint
                cleared?.supportsMIDI2 = false
                let withoutAnswer = Self.facts(base.endpoint, blocks, .missing)
                let noEndpoint = Self.facts(nil, [], reply)
                let noMIDI2 = Self.facts(cleared, blocks, reply)
                let baseRank = try Self.negotiated(base).level.rank
                let rankMissing = try Self.negotiated(withoutAnswer).level.rank
                let rankNoEndpoint = try Self.negotiated(noEndpoint).level.rank
                let rankNoMIDI2 = try Self.negotiated(noMIDI2).level.rank
                #expect(rankMissing <= baseRank, "\(kind) \(blockCount) missing")
                #expect(rankNoEndpoint <= baseRank, "\(kind) \(blockCount) no endpoint")
                #expect(rankNoMIDI2 <= baseRank, "\(kind) \(blockCount) cleared")
                checked += 1
            }
        }
        #expect(checked == 9)
    }

    @Test func theRanksAreTheLiteralValuesZeroOneAndTwo() {
        let ranks = Level.allCases.map(\.rank)
        let expected = [0, 1, 2]
        #expect(ranks == expected)
        let cases: [Level] = [.legacyByteStream, .umpMIDI1, .umpMIDI2]
        #expect(Level.allCases == cases)
    }

    // MARK: - Features

    @Test func aFullMIDI2EndpointWithBlocksAndProfilesGrantsEverySixFeaturesInDeclarationOrder() throws {
        let profiles = [try Self.profile(2), try Self.profile(1)]
        let result = try Self.negotiated(try Self.full(blocks: Self.tiles(2), profiles: profiles))
        let expected: [Feature] = [
            .umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks, .ciDiscovery, .profileConfiguration
        ]
        #expect(result.features == expected)
        #expect(Feature.allCases == expected)
    }

    @Test func aMIDI1OnlyEndpointGrantsEverythingButTheMIDI2Protocol() throws {
        let ump = Self.endpoint(midi1: true, midi2: false, receives: true, declared: 1)
        let base = Self.facts(ump, [Self.tile(0)], try Self.answer())
        let result = try Self.negotiated(base)
        let expected: [Feature] = [.umpTransport, .jitterReduction, .functionBlocks, .ciDiscovery]
        #expect(result.features == expected)
        #expect(result.level == Level.umpMIDI1)
    }

    @Test func noEndpointWithAnAnswerGrantsOnlyDiscoveryAndNoEndpointWithoutOneGrantsNothing() throws {
        let answered = try Self.negotiated(Self.facts(nil, [], try Self.answer()))
        let missing = try Self.negotiated(Self.facts(nil, [], .missing))
        let onlyDiscovery: [Feature] = [.ciDiscovery]
        let nothing: [Feature] = []
        #expect(answered.features == onlyDiscovery)
        #expect(missing.features == nothing)
    }

    struct JitterCase {
        let receives: Bool
        let transmits: Bool
        let granted: Bool
    }

    @Test func jitterReductionFollowsReceivingOrTransmittingAndNeedsAUMPLevel() throws {
        let cases = [
            JitterCase(receives: false, transmits: false, granted: false),
            JitterCase(receives: true, transmits: false, granted: true),
            JitterCase(receives: false, transmits: true, granted: true),
            JitterCase(receives: true, transmits: true, granted: true)
        ]
        for item in cases {
            let ump = Self.endpoint(midi1: true, midi2: true, receives: item.receives, transmits: item.transmits)
            let result = try Self.negotiated(Self.facts(ump, [], try Self.answer()))
            let granted = result.features.contains(.jitterReduction)
            #expect(granted == item.granted, "\(item)")
            let none = Self.endpoint(midi1: false, midi2: false, receives: item.receives, transmits: item.transmits)
            let legacyResult = try Self.negotiated(Self.facts(none, [], try Self.answer()))
            let legacyGranted = legacyResult.features.contains(.jitterReduction)
            #expect(legacyGranted == false, "legacy \(item)")
        }
    }

    @Test func theFunctionBlocksFeatureNeedsOneActiveBlockAndRecordsNoDowngradeWithout() throws {
        let inactiveOnly = [Self.tile(0, active: false), Self.tile(1, active: false)]
        let noneActive = try Self.negotiated(try Self.full(blocks: inactiveOnly))
        #expect(noneActive.features.contains(.functionBlocks) == false)
        let noDowngrades: [MIDICapabilityDowngrade] = []
        #expect(noneActive.downgrades == noDowngrades)
        let oneActive = try Self.negotiated(try Self.full(blocks: [Self.tile(0, active: false), Self.tile(1)]))
        #expect(oneActive.features.contains(.functionBlocks))
        let emptyList = try Self.negotiated(try Self.full())
        #expect(emptyList.features.contains(.functionBlocks) == false)
        let legacyFacts = Self.facts(Self.endpoint(midi1: true, midi2: true, declared: 1), [Self.tile(0)], .missing)
        let legacy = try Self.negotiated(legacyFacts)
        #expect(legacy.features.contains(.functionBlocks) == false)
    }

    @Test func theFunctionBlockListIsSortedAtAUMPLevelAndEmptyAtTheLegacyLevel() throws {
        let unsorted = [Self.tile(2), Self.tile(0, active: false), Self.tile(1)]
        let sorted = [Self.tile(0, active: false), Self.tile(1), Self.tile(2)]
        let ump = try Self.negotiated(try Self.full(blocks: unsorted))
        #expect(ump.functionBlocks == sorted)
        let legacyFacts = Self.facts(Self.endpoint(midi1: true, midi2: true, declared: 3), unsorted, .missing)
        let legacy = try Self.negotiated(legacyFacts)
        let none: [Block] = []
        #expect(legacy.functionBlocks == none)
        #expect(legacy.features.contains(.functionBlocks) == false)
    }

    @Test func legacyFactsWithAnInvalidBlockAreRefusedAndNotRepaired() {
        let bad = Self.block(3, first: 0, count: 0)
        let legacyFacts = Self.facts(Self.endpoint(midi1: true, midi2: true, declared: 1), [bad], .missing)
        let expected: MIDICapabilityRefusal = .functionBlockInvalid(index: 3, .invalidField(.groupCount, value: 0))
        #expect(Self.refusal(legacyFacts) == expected)
    }

    @Test func profileConfigurationNeedsTheCategoryBitAndAtLeastOneProfile() throws {
        let advertised = [try Self.profile(9), try Self.profile(4)]
        let announced = try Self.negotiated(try Self.full(profiles: advertised))
        #expect(announced.features.contains(.profileConfiguration))
        let sortedProfiles = [try Self.profile(4), try Self.profile(9)]
        #expect(announced.profiles == sortedProfiles)
        let silent = try Self.negotiated(try Self.full(category: Self.silentCategory, profiles: advertised))
        #expect(silent.features.contains(.profileConfiguration) == false)
        let none: [MIDICapabilityProfileID] = []
        #expect(silent.profiles == none)
        let announcedEmpty = try Self.negotiated(try Self.full())
        #expect(announcedEmpty.features.contains(.profileConfiguration) == false)
        #expect(announcedEmpty.profiles == none)
        let silentEmpty = try Self.negotiated(try Self.full(category: Self.silentCategory))
        #expect(silentEmpty.features.contains(.profileConfiguration) == false)
    }

    @Test func profileConfigurationIsGrantedEvenAtTheLegacyLevelWhenTheAnswerAnnouncesIt() throws {
        let advertised = [try Self.profile(7)]
        let result = try Self.negotiated(Self.facts(nil, [], try Self.answer(profiles: advertised)))
        let expected: [Feature] = [.ciDiscovery, .profileConfiguration]
        #expect(result.features == expected)
        #expect(result.profiles == advertised)
        #expect(result.level == Level.legacyByteStream)
    }

    // MARK: - Profile identifiers

    @Test func aProfileIdentifierIsExactlyFiveSevenBitBytes() throws {
        let four = Self.profileRefusal([1, 2, 3, 4])
        let six = Self.profileRefusal([1, 2, 3, 4, 5, 6])
        let empty = Self.profileRefusal([])
        #expect(four == MIDICapabilityRefusal.invalidProfileID(count: 4, offset: 0))
        #expect(six == MIDICapabilityRefusal.invalidProfileID(count: 6, offset: 0))
        #expect(empty == MIDICapabilityRefusal.invalidProfileID(count: 0, offset: 0))
        let five = try MIDICapabilityProfileID.make(bytes: [1, 2, 3, 4, 5])
        #expect(five.bytes == [1, 2, 3, 4, 5])
        let boundary = Self.profileRefusal([0x7F, 0x7F, 0x7F, 0x7F, 0x7F])
        #expect(boundary == nil)
        let highest = try MIDICapabilityProfileID.make(bytes: [0x7F, 0x7F, 0x7F, 0x7F, 0x7F])
        #expect(highest.bytes == [0x7F, 0x7F, 0x7F, 0x7F, 0x7F])
    }

    @Test func aProfileByteAbove0x7FIsRefusedWithThePositionOfTheFirstOffendingByte() {
        let first = Self.profileRefusal([0x80, 1, 2, 3, 4])
        let last = Self.profileRefusal([1, 2, 3, 4, 0x80])
        let two = Self.profileRefusal([1, 2, 0xFF, 4, 0x80])
        #expect(first == MIDICapabilityRefusal.invalidProfileID(count: 5, offset: 0))
        #expect(last == MIDICapabilityRefusal.invalidProfileID(count: 5, offset: 4))
        #expect(two == MIDICapabilityRefusal.invalidProfileID(count: 5, offset: 2))
    }

    @Test func aLengthErrorIsReportedBeforeAnOffendingByte() {
        let result = Self.profileRefusal([0x80, 0x80])
        #expect(result == MIDICapabilityRefusal.invalidProfileID(count: 2, offset: 0))
    }

    // MARK: - Maxima

    @Test func sixteenFunctionBlocksAndSixtyFourProfilesAreAccepted() throws {
        var profiles: [MIDICapabilityProfileID] = []
        for number in 0..<MIDICapabilityLimits.maximumProfiles {
            profiles.append(try Self.profile(UInt8(number)))
        }
        let result = try Self.negotiated(try Self.full(blocks: Self.tiles(16), profiles: profiles))
        #expect(result.functionBlocks.count == 16)
        #expect(result.profiles.count == 64)
        #expect(MIDICapabilityLimits.maximumFunctionBlocks == 32)
        #expect(MIDICapabilityLimits.maximumProfiles == 64)
    }
}
