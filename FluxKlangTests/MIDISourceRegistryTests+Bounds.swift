import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDISourceRegistryTests {
    private static let invalidSources = MIDISourceRefusal.invalidConfiguration(.maximumSources)
    private static let invalidFeed = MIDISourceRefusal.invalidConfiguration(.maximumFeedBytes)
    private static let invalidSysEx = MIDISourceRefusal.invalidConfiguration(.maximumSysExPayloadBytes)

    private static func half(_ raws: [UInt32], limit: Int = 4_096) throws -> MIDISourceRegistry {
        var registry = try Self.registry(raws, maximumFeedBytes: limit)
        for raw in raws { _ = try registry.feed([0x90, UInt8(raw)], from: Self.id(raw)) }
        return registry
    }

    @Test func theSourceLimitAccepts1And128AndRefusesZero129AndNegatives() throws {
        #expect(try MIDISourceRegistry.make(maximumSources: 1).maximumSources == 1)
        #expect(try MIDISourceRegistry.make(maximumSources: 128).maximumSources == 128)
        for bad in [0, 129, -1, Int.min, Int.max] {
            #expect(Self.refusal { try MIDISourceRegistry.make(maximumSources: bad) } == Self.invalidSources)
        }
        let defaults = try MIDISourceRegistry.make()
        #expect(defaults.maximumSources == 32 && defaults.maximumFeedBytes == 4_096 && defaults.count == 0)
        #expect(defaults.sources.isEmpty && defaults.snapshot.sources.isEmpty)
    }

    @Test func theFeedLimitAccepts1And65536AndRefusesZero65537AndNegatives() throws {
        #expect(try MIDISourceRegistry.make(maximumFeedBytes: 1).maximumFeedBytes == 1)
        #expect(try MIDISourceRegistry.make(maximumFeedBytes: 65_536).maximumFeedBytes == 65_536)
        for bad in [0, 65_537, -1, Int.min, Int.max] {
            #expect(Self.refusal { try MIDISourceRegistry.make(maximumFeedBytes: bad) } == Self.invalidFeed)
        }
        let refusal = Self.refusal { try MIDISourceRegistry.make(maximumSources: 0, maximumFeedBytes: 0) }
        #expect(refusal == Self.invalidSources)
    }

    @Test func theSysExBoundOfAProfileAccepts1And65536AndRefusesZero65537AndNegatives() throws {
        #expect(try Self.profile(sysEx: 1).maximumSysExPayloadBytes == 1)
        #expect(try Self.profile(sysEx: 65_536).maximumSysExPayloadBytes == 65_536)
        for bad in [0, 65_537, -1, Int.min, Int.max] {
            #expect(Self.refusal { try Self.profile(sysEx: bad) } == Self.invalidSysEx)
        }
        let standard = MIDISourceProfile.standard
        #expect(standard.maximumSysExPayloadBytes == 4_096 && standard.statePolicy == .standard)
        #expect(try MIDISourceProfile.make() == standard)
    }

    @Test func sourcesUpToTheLimitAreAcceptedAndOneMoreIsRegistryFull() throws {
        var full = try Self.registry([1, 2, 3], maximumSources: 3)
        #expect(full.count == 3)
        _ = try full.feed([0x90, 4], from: Self.id(1))
        let before = full
        #expect(Self.refusal { try full.register(Self.id(4), key: Self.key(4)) } == .registryFull(limit: 3))
        #expect(full.snapshot == before.snapshot)
        #expect(try Self.continuation(full) == Self.continuation(before))
        var widest = try MIDISourceRegistry.make(maximumSources: 128)
        for raw in UInt32(0)..<128 { try widest.register(Self.id(raw), key: Self.key(UInt64(raw))) }
        #expect(widest.count == 128)
        #expect(Self.refusal { try widest.register(Self.id(128), key: Self.key(128)) } == .registryFull(limit: 128))
        #expect(widest.count == 128)
    }

    @Test func detachingASourceFreesItsSlotInAFullRegistry() throws {
        var registry = try Self.registry([1, 2], maximumSources: 2)
        _ = try registry.detach(Self.id(1))
        try registry.register(Self.id(3), key: Self.key(3))
        #expect(registry.sources.map(\.input) == [Self.id(2), Self.id(3)])
        #expect(Self.refusal { try registry.register(Self.id(1), key: Self.key(1)) } == .registryFull(limit: 2))
    }

    @Test func aFeedOfExactlyTheLimitIsAcceptedAndOneMoreByteIsTooLarge() throws {
        var registry = try Self.registry([1, 2], maximumFeedBytes: 65_536)
        let outputs = try registry.feed(Array(repeating: 0xF8, count: 65_536), from: Self.id(1))
        #expect(outputs.count == 65_536)
        let before = registry
        let refused = Self.refusal { try registry.feed(Array(repeating: 0xF8, count: 65_537), from: Self.id(1)) }
        #expect(refused == .feedTooLarge(count: 65_537, limit: 65_536))
        #expect(registry.snapshot == before.snapshot)
        var small = try Self.registry([1], maximumFeedBytes: 4)
        #expect(try small.feed(Self.noteOn(1, 60) + [0xF8], from: Self.id(1)).count == 2)
        #expect(Self.refusal { try small.feed([0xF8, 0xF8, 0xF8, 0xF8, 0xF8], from: Self.id(1)) }
            == .feedTooLarge(count: 5, limit: 4))
    }

    @Test func anOversizeFeedIsRefusedBeforeAnyByteIsConsumed() throws {
        var registry = try Self.half([1, 2], limit: 3)
        let before = registry
        let completes: [UInt8] = [100, 0x90, 61, 100]
        #expect(Self.refusal { try registry.feed(completes, from: Self.id(1)) } == .feedTooLarge(count: 4, limit: 3))
        #expect(Self.refusal { try registry.feed(Self.noteOn(1, 70) + [0xFF], from: Self.id(2)) }
            == .feedTooLarge(count: 4, limit: 3))
        #expect(registry.snapshot == before.snapshot)
        #expect(Self.held(registry, 1).isEmpty)
        #expect(try Self.continuation(registry) == Self.continuation(before))
        #expect(try Self.continuation(registry).allSatisfy { !$0.isEmpty })
    }

    @Test func anUnknownInputIsRefusedBeforeTheSizeIsChecked() throws {
        var registry = try Self.half([1], limit: 3)
        let before = registry
        #expect(Self.refusal { try registry.feed([1, 2, 3, 4], from: Self.id(9)) } == .unknownInput(Self.id(9)))
        #expect(Self.refusal { try registry.feed([], from: Self.id(9)) } == .unknownInput(Self.id(9)))
        #expect(registry.snapshot == before.snapshot)
        #expect(try Self.continuation(registry) == Self.continuation(before))
    }

    @Test func anEmptyFeedReturnsNoOutputsAndKeepsAHalfMessage() throws {
        var registry = try Self.half([1])
        let before = registry
        #expect(try registry.feed([], from: Self.id(1)).isEmpty)
        #expect(registry.snapshot == before.snapshot)
        #expect(try Self.continuation(registry) == Self.continuation(before))
        #expect(try Self.continuation(registry).first?.isEmpty == false)
    }

    @Test func aFeedNeverEmitsMoreOutputsThanItHasBytes() throws {
        for seed in UInt64(1)...6 {
            var registry = try Self.registry([1])
            let bytes = Self.stream(count: 4_096, seed: seed)
            let outputs = try registry.feed(bytes, from: Self.id(1))
            #expect(outputs.count <= bytes.count && !outputs.isEmpty)
        }
        var registry = try Self.registry([1])
        let exact = try registry.feed(Self.noteOn(1, 60) + [0xF8, 0xF8], from: Self.id(1))
        #expect(exact.count == 3)
    }

    @Test func aSourceUsesTheSysExBoundOfItsOwnProfile() throws {
        var registry = try Self.registry([])
        try registry.register(Self.id(1), key: Self.key(1), profile: Self.profile(sysEx: 3))
        try registry.register(Self.id(2), key: Self.key(2), profile: Self.profile(sysEx: 1))
        let fits = try registry.feed([0xF0, 1, 2, 3, 0xF7], from: Self.id(1))
        #expect(Self.events(fits) == [.sysEx(payload: [1, 2, 3])])
        let over = try registry.feed([0xF0, 1, 2, 3, 4, 0xF7] + Self.noteOn(1, 60), from: Self.id(1))
        #expect(Self.events(over) == [.channel(status: 0x90, data1: 60, data2: 100)])
        #expect(Self.events(try registry.feed([0xF0, 9, 0xF7], from: Self.id(2))) == [.sysEx(payload: [9])])
        #expect(try registry.feed([0xF0, 9, 9, 0xF7], from: Self.id(2)).isEmpty)
        #expect(Self.events(try registry.feed([0xF0, 1, 2, 3, 0xF7], from: Self.id(2))).isEmpty)
    }

    @Test func aSysExOfExactlyTheMaximumBoundSurvivesFeedsAndOneMoreByteIsDiscarded() throws {
        let profile = try Self.profile(sysEx: 65_536)
        var registry = try Self.registry([1], profile: profile, maximumFeedBytes: 65_536)
        let head = [0xF0] + Array(repeating: UInt8(1), count: 40_000)
        let fits = try Self.feedChunks(
            &registry, [head, Array(repeating: 1, count: 25_536) + [0xF7]], from: 1
        )
        #expect(Self.events(fits) == [.sysEx(payload: Array(repeating: 1, count: 65_536))])
        let over = try Self.feedChunks(
            &registry, [head, Array(repeating: 1, count: 25_537) + [0xF7]], from: 1
        )
        #expect(over.isEmpty)
        #expect(Self.events(try registry.feed(Self.noteOn(1, 60), from: Self.id(1))).count == 1)
    }

    @Test func aHeldNoteLimitRefusalIsOutputInOrderAndLaterBytesStillApply() throws {
        let profile = try Self.profile(policy: Self.policy(heldNotes: 2))
        var registry = try Self.registry([1], profile: profile)
        let bytes = Self.noteOn(1, 60) + Self.noteOn(1, 61) + Self.noteOn(1, 62)
            + Self.noteOff(1, 60) + Self.noteOn(1, 62) + Self.control(1, 7, 9)
        let outputs = try registry.feed(bytes, from: Self.id(1))
        try #require(outputs.count == 6)
        #expect(outputs[2].outcome == .refused(.heldNoteLimit(channel: 1, note: 62)))
        #expect(outputs[2].event == .channel(status: 0x90, data1: 62, data2: 100))
        #expect(outputs.enumerated().filter { $0.offset != 2 }.allSatisfy { $0.element.performanceEvent != nil })
        #expect(Self.held(registry, 1).map(\.note) == [61, 62])
    }

    @Test func otherStateRefusalsAreOutputsToo() throws {
        let profile = try Self.profile(policy: Self.policy(parameters: 1))
        var registry = try Self.registry([1], profile: profile)
        let bytes = Self.control(1, 6, 1) + Self.selectRPN(1, msb: 0, lsb: 0) + Self.control(1, 6, 1)
            + Self.selectRPN(1, msb: 0, lsb: 1) + Self.control(1, 6, 1) + Self.control(1, 123, 0)
        let outcomes = try registry.feed(bytes, from: Self.id(1)).map(\.outcome)
        try #require(outcomes.count == 8)
        #expect(outcomes[0] == .refused(.noParameterSelected(channel: 1, controller: 6)))
        #expect(outcomes[6] == .refused(.parameterStoreFull(channel: 1)))
        #expect(outcomes.filter { if case .refused = $0 { true } else { false } }.count == 2)
        #expect(Self.state(registry, 1)?.channels[0].parameters.count == 1)
    }
}
