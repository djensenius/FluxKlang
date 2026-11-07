import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDISourceRegistryTests {
    /// A registry whose sources hold a half message, a note and a selected parameter, so that any change is visible.
    private static func busyRegistry(_ raws: [UInt32]) throws -> MIDISourceRegistry {
        var registry = try Self.registry(raws)
        for raw in raws {
            let bytes = Self.noteOn(1, UInt8(raw)) + Self.selectRPN(2, msb: 0, lsb: 1) + [0x90, 9]
            _ = try registry.feed(bytes, from: Self.id(raw))
        }
        return registry
    }

    @Test func anEqualKeyIsRefusedAsAmbiguousAndTheExistingSourceIsNeverReassigned() throws {
        var registry = try Self.busyRegistry([5])
        let before = registry
        let refused = Self.refusal { try registry.register(Self.id(6), key: Self.key(5)) }
        #expect(refused == .ambiguousEndpoint(existing: Self.id(5)))
        #expect(registry.snapshot == before.snapshot)
        #expect(registry.sources.map(\.input) == [Self.id(5)])
        #expect(try Self.continuation(registry) == Self.continuation(before))
    }

    @Test func theRefusalNamesTheLiveSourceThatOwnsTheKey() throws {
        var registry = try Self.registry([1, 2, 3])
        for fingerprint in [UInt64(3), 1, 2] {
            let refusal = Self.refusal { try registry.register(Self.id(9), key: Self.key(fingerprint)) }
            #expect(refusal == .ambiguousEndpoint(existing: Self.id(UInt32(fingerprint))))
        }
    }

    @Test func aDifferentOrdinalResolvesTheAmbiguityAndKeepsBothSourcesSeparate() throws {
        var registry = try Self.registry([])
        try registry.register(Self.id(1), key: Self.key(77))
        try registry.register(Self.id(2), key: Self.key(77, 1))
        _ = try registry.feed(Self.noteOn(1, 60), from: Self.id(1))
        #expect(registry.sources.map(\.key) == [Self.key(77), Self.key(77, 1)])
        #expect(Self.held(registry, 1).count == 1)
        #expect(Self.held(registry, 2).isEmpty)
    }

    @Test func ordinal255IsAcceptedAndDistinctFromItsNeighbours() throws {
        var registry = try Self.registry([])
        try registry.register(Self.id(1), key: Self.key(5, 255))
        try registry.register(Self.id(2), key: Self.key(5, 254))
        try registry.register(Self.id(3), key: Self.key(5, 0))
        let refusal = Self.refusal { try registry.register(Self.id(4), key: Self.key(5, 255)) }
        #expect(refusal == .ambiguousEndpoint(existing: Self.id(1)))
        #expect(registry.count == 3)
    }

    @Test func theFingerprintDistinguishesSourcesWithTheSameOrdinal() throws {
        var registry = try Self.registry([])
        try registry.register(Self.id(1), key: Self.key(0))
        try registry.register(Self.id(2), key: Self.key(.max))
        try registry.register(Self.id(3), key: Self.key(.max - 1))
        #expect(registry.count == 3)
        let refusal = Self.refusal { try registry.register(Self.id(4), key: Self.key(.max)) }
        #expect(refusal == .ambiguousEndpoint(existing: Self.id(2)))
    }

    @Test func theDefaultOrdinalIsZero() {
        #expect(MIDIEndpointKey(fingerprint: 9) == Self.key(9, 0))
        #expect(MIDIEndpointKey(fingerprint: 9) != Self.key(9, 1))
        #expect(Self.key(1, 255) < Self.key(2, 0) && Self.key(2, 0) < Self.key(2, 1))
    }

    @Test func detachFreesTheKeyAndAReRegisteredInputStartsFresh() throws {
        var registry = try Self.busyRegistry([1, 2])
        _ = try registry.detach(Self.id(1))
        #expect(registry.sources.map(\.input) == [Self.id(2)])
        try registry.register(Self.id(1), key: Self.key(1))
        #expect(Self.held(registry, 1).isEmpty)
        #expect(Self.state(registry, 1) == Self.state(try Self.registry([1]), 1))
        #expect(try registry.feed(Self.probe, from: Self.id(1)).count == 1)
        try registry.register(Self.id(3), key: Self.key(1, 1))
        #expect(registry.count == 3)
    }

    @Test func detachingAMiddleSourceReportsOnlyItsNotesAndKeepsTheOthersInOrder() throws {
        var registry = try Self.registry([1, 2, 3])
        for raw in UInt32(1)...3 { _ = try registry.feed(Self.noteOn(1, UInt8(raw * 10)), from: Self.id(raw)) }
        let report = try registry.detach(Self.id(2))
        #expect(report == [MIDISourceRelease(channel: 1, note: 20, phase: .keyDown)])
        #expect(registry.sources.map(\.input) == [Self.id(1), Self.id(3)])
        #expect(Self.held(registry, 1).map(\.note) == [10])
        #expect(Self.held(registry, 3).map(\.note) == [30])
        #expect(Self.refusal { try registry.detach(Self.id(2)) } == .unknownInput(Self.id(2)))
    }

    @Test func aDuplicateInputIsRefusedFirstWhateverItsKey() throws {
        var registry = try Self.busyRegistry([1, 2])
        let before = registry
        #expect(Self.refusal { try registry.register(Self.id(2), key: Self.key(99)) } == .duplicateInput(Self.id(2)))
        #expect(Self.refusal { try registry.register(Self.id(2), key: Self.key(1)) } == .duplicateInput(Self.id(2)))
        #expect(Self.refusal { try registry.register(Self.id(2), key: Self.key(2)) } == .duplicateInput(Self.id(2)))
        #expect(registry.snapshot == before.snapshot)
        #expect(try Self.continuation(registry) == Self.continuation(before))
    }

    @Test func anyUInt32IsAValidInputID() throws {
        var registry = try Self.registry([])
        for raw in [UInt32.max, 0, 1, UInt32.max - 1] {
            try registry.register(Self.id(raw), key: Self.key(UInt64(raw)))
        }
        #expect(registry.sources.map(\.input.rawValue) == [0, 1, UInt32.max - 1, UInt32.max])
        #expect(try registry.feed(Self.noteOn(1, 1), from: Self.id(UInt32.max)).count == 1)
        #expect(try registry.feed(Self.noteOn(1, 1), from: Self.id(0)).count == 1)
    }

    @Test func sourcesAndTheSnapshotAreAscendingWhateverTheRegistrationOrder() throws {
        let raws: [UInt32] = [90, 7, 300, 0, 41, UInt32.max, 8]
        let descending = try Self.registry(raws.sorted(by: >))
        let shuffled = try Self.registry(raws)
        let ascending = try Self.registry(raws.sorted())
        #expect(shuffled.sources.map(\.input.rawValue) == raws.sorted())
        #expect(descending.sources.map(\.input.rawValue) == raws.sorted())
        #expect(shuffled.snapshot.sources.map(\.input.rawValue) == raws.sorted())
        #expect(descending.snapshot == ascending.snapshot)
        #expect(shuffled.snapshot == ascending.snapshot)
    }

    @Test func anEqualKeyIsReportedAsAmbiguousEvenWhenTheRegistryIsFull() throws {
        var registry = try Self.registry([1, 2], maximumSources: 2)
        let refusal = Self.refusal { try registry.register(Self.id(3), key: Self.key(2)) }
        #expect(refusal == .ambiguousEndpoint(existing: Self.id(2)))
        #expect(Self.refusal { try registry.register(Self.id(3), key: Self.key(3)) } == .registryFull(limit: 2))
    }

    @Test func aRegisteredSourceReportsItsKeyAndProfile() throws {
        var registry = try Self.registry([])
        let profile = try Self.profile(reset: .resetSource, sysEx: 33, policy: Self.policy(heldNotes: 7))
        try registry.register(Self.id(3), key: Self.key(8, 2), profile: profile)
        #expect(registry.sources == [MIDISourceDescriptor(input: Self.id(3), key: Self.key(8, 2), profile: profile)])
        #expect(registry.snapshot.sources.first?.profile == profile)
        #expect(registry.snapshot.sources.first?.key == Self.key(8, 2))
    }
}
