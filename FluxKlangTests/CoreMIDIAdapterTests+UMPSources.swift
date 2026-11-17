import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    static func umpRegistry(maximumBytes: Int = 65_535, profile: MIDISourceProfile = .unpaired)
        throws -> MIDISourceRegistry {
        var registry = try MIDISourceRegistry.make(
            maximumFeedBytes: maximumBytes, umpSplitter: LaunchControlXLStream.umpSplitter
        )
        try registry.register(MIDIInputID(1), key: MIDIEndpointKey(fingerprint: 1), profile: profile)
        return registry
    }

    @Test func eventPacketRefusalRollsBackParserDecoderAndPerformanceWithNoPrefix() throws {
        let input = MIDIInputID(1)
        let rejected: [[UInt32]] = [
            [0x2090_3C7F, 0x3000_0000],             // truncated after a valid Note On
            [0x2090_3C7F, 0x20BF_0580],             // typed malformed after a valid Note On
            [0x2090_3C7F, 0x3012_0203, 0, 0x20BF_0580] // candidate decoder starts a different SysEx
        ]
        for words in rejected {
            var registry = try Self.umpRegistry()
            #expect(try registry.feedUMP([0x3011_0100, 0], from: input).isEmpty)
            let before = registry.snapshot
            #expect(throws: MIDIUMPSourceRefusal.self) { try registry.feedUMP(words, from: input) }
            #expect(registry.snapshot == before)
            #expect(try registry.feedUMP([0x3031_0400, 0], from: input).map(\.event) == [.sysEx(payload: [1, 4])])
        }
        var small = try Self.umpRegistry(maximumBytes: 3)
        let before = small.snapshot
        #expect(throws: MIDIUMPSourceRefusal.source(.feedTooLarge(count: 6, limit: 3))) {
            try small.feedUMP([0x2090_3C7F, 0x20BF_057F], from: input)
        }
        #expect(small.snapshot == before)
        #expect(try small.feedUMP([0x20BF_067F], from: input).map(\.event) == [Self.cc(6, 127)])
        #expect(throws: MIDIUMPSourceRefusal.source(.unknownInput(MIDIInputID(99)))) {
            try small.feedUMP([0x3000_0000], from: MIDIInputID(99))
        }
    }

    @Test func umpSystemResetOrderingResetsThePairOnlyWhenProfileRequires() throws {
        for policy: MIDISystemResetPolicy in [.resetSource, .ignore] {
            let profile = try MIDISourceProfile.make(systemReset: policy)
            var registry = try Self.umpRegistry(profile: profile)
            let input = MIDIInputID(1)
            // Start, reset, end: resetSource makes the end orphan; ignore retains the open pair.
            let outputs = try registry.feedUMP([0x3011_0100, 0, 0x10FF_0000, 0x3031_0200, 0], from: input)
            let expected: [MIDI1Event] = policy == .resetSource
                ? [.realTime(status: 0xFF)] : [.realTime(status: 0xFF), .sysEx(payload: [1, 2])]
            #expect(outputs.map(\.event) == expected)
            _ = try registry.resetSource(input)
            // Reset then start: a decode-all-before-feed implementation destroys this new start.
            #expect(try registry.feedUMP([0x10FF_0000, 0x3011_0300, 0], from: input).map(\.event) == [
                .realTime(status: 0xFF)
            ])
            #expect(try registry.feedUMP([0x3031_0400, 0], from: input).map(\.event) == [.sysEx(payload: [3, 4])])
        }
    }

    @Test func nonfatalSkipsKeepSysExAndGroupsMergeWithoutCrossSplicing() throws {
        var registry = try Self.umpRegistry()
        let input = MIDIInputID(1)
        #expect(try registry.feedUMP([0x3511_0100, 0], from: input).isEmpty)
        let skipped: [UInt32] = [
            0, 0x4090_3C00, 0xFFFF_0000, 0x5000_0000, 0, 0, 0,
            0x3631_7F00, 0, 0x1FF8_0000
        ]
        #expect(try registry.feedUMP(skipped, from: input).map(\.event) == [.realTime(status: 0xF8)])
        #expect(try registry.feedUMP([0x3531_0200, 0], from: input).map(\.event) == [.sysEx(payload: [1, 2])])
        #expect(try registry.feedUMP([0x3531_0300, 0, 0x2FBF_057F, 0x21BF_0601], from: input).map(\.event) == [
            Self.cc(5, 127), Self.cc(6, 1)
        ])
        #expect(try registry.feedUMP([0x3511_0100, 0, 0x3611_0200, 0], from: input).isEmpty)
        let replaced = try registry.feedUMP([0x3531_0300, 0, 0x3631_0400, 0], from: input)
        #expect(replaced.map(\.event) == [.sysEx(payload: [2, 4])])
    }

    @Test func resolvedPairsAreIndependentAcrossCallbacksAndFallbackSharesExactlyOnePair() throws {
        var stream = try LaunchControlXLStream.make(backend: .experimentalMIDI1UMP)
        let first = try Self.connected(1, "A", fingerprint: 1)
        let second = try Self.connected(2, "B", fingerprint: 2)
        let shared = try Self.connected(3, "C", fingerprint: nil)
        let otherShared = try Self.connected(4, "D", fingerprint: nil)
        stream.connect([first, second, shared, otherShared])
        #expect(stream.feedUMP(packets: [[0x3311_0100, 0]], from: first.token).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3311_0200, 0]], from: second.token).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3311_0300, 0]], from: shared.token).isEmpty)
        let completed = stream.feedUMP(packets: [[0x3331_0400, 0]], from: otherShared.token)
        #expect(completed.map(\.event) == [.sysEx(payload: [3, 4])])
        #expect(completed.map(\.input) == [LaunchControlXLStream.input])
        let one = stream.feedUMP(packets: [[0x3331_0500, 0]], from: first.token)
        let two = stream.feedUMP(packets: [[0x3331_0600, 0]], from: second.token)
        #expect(one.map(\.event) == [.sysEx(payload: [1, 5])])
        #expect(two.map(\.event) == [.sysEx(payload: [2, 6])])
        #expect(one.first?.input != two.first?.input)

        let fitting = try (1...31).map { try Self.connected(UInt($0), "Unit \($0)", fingerprint: UInt64($0)) }
        let extra = try Self.connected(32, "Full", fingerprint: 32)
        let unresolved = try Self.connected(33, "Shared", fingerprint: nil)
        stream.connect(fitting + [extra, unresolved])
        #expect(stream.sources.last?.isResolved == false)
        #expect(stream.sources[31].isResolved == false)
        #expect(stream.feedUMP(packets: [[0x3011_0700, 0]], from: extra.token).isEmpty)
        let fallback = stream.feedUMP(packets: [[0x3031_0800, 0]], from: unresolved.token)
        #expect(fallback.map(\.event) == [.sysEx(payload: [7, 8])])
        #expect(stream.snapshot.sources.count == 32)
    }

    @Test func eventFragmentsNeverJoinAndRefusalResetsOnlyTheEffectivePair() throws {
        var stream = try LaunchControlXLStream.make(backend: .experimentalMIDI1UMP)
        let first = try Self.connected(1, "A", fingerprint: 1)
        let second = try Self.connected(2, "B", fingerprint: 2)
        stream.connect([first, second])
        for source in [first, second] {
            #expect(stream.feedUMP(packets: [[0x3011_0100, 0]], from: source.token).isEmpty)
        }
        // A valid CC prefix must not escape the refused event packet, nor may the next packet repair its tail.
        #expect(stream.feedUMP(packets: [[0x20BF_057F, 0x3000_0000], [0]], from: first.token).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3031_0200, 0]], from: first.token).isEmpty)
        let retained = stream.feedUMP(packets: [[0x3031_0300, 0]], from: second.token)
        #expect(retained.map(\.event) == [.sysEx(payload: [1, 3])])
        #expect(stream.feedUMP(packets: [[0x20BF_067F]], from: first.token).map(\.event) == [Self.cc(6, 127)])
        #expect(stream.feedUMP(packets: [[0x3011_0100, 0]]).isEmpty)
        #expect(stream.feedUMP(packets: [[0x20BF_0580]]).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3031_0200, 0]]).isEmpty)
    }

    @Test func umpRekeyDetachKeepAndSharedResetHaveSourceLifetimes() throws {
        var stream = try LaunchControlXLStream.make(backend: .experimentalMIDI1UMP)
        let first = try Self.connected(1, "A", fingerprint: 1)
        let shared = try Self.connected(2, "Shared", fingerprint: nil)
        let joining = try Self.connected(3, "Joining", fingerprint: nil)
        stream.connect([first, shared])
        #expect(stream.feedUMP(packets: [[0x3011_0100, 0]], from: first.token).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3011_0200, 0]], from: shared.token).isEmpty)
        let changed = stream.connect([first, shared, joining])
        #expect(changed)
        let kept = stream.feedUMP(packets: [[0x3031_0300, 0]], from: shared.token)
        #expect(kept.map(\.event) == [.sysEx(payload: [2, 3])])
        #expect(stream.feedUMP(packets: [[0x3011_0400, 0]], from: shared.token).isEmpty)
        stream.resetSharedSource()
        #expect(stream.feedUMP(packets: [[0x3031_0500, 0]], from: shared.token).isEmpty)
        let independent = stream.feedUMP(packets: [[0x3031_0600, 0]], from: first.token)
        #expect(independent.map(\.event) == [.sysEx(payload: [1, 6])])

        #expect(stream.feedUMP(packets: [[0x3011_0100, 0]], from: first.token).isEmpty)
        let rekey = try Self.connected(1, "A", fingerprint: 10)
        stream.connect([rekey, shared])
        #expect(stream.feedUMP(packets: [[0x3031_0200, 0]], from: rekey.token).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3011_0100, 0]], from: rekey.token).isEmpty)
        stream.connect([shared])
        #expect(stream.feedUMP(packets: [[0x20BF_057F]], from: rekey.token).isEmpty)
        #expect(stream.droppedBatches == 1)
        stream.connect([rekey, shared])
        #expect(stream.feedUMP(packets: [[0x3031_0200, 0]], from: rekey.token).isEmpty)
    }

    @Test func observedOfflineRetiresResolvedUMPPairAndPreservesGapFreePeer() throws {
        let first = Self.source(10, "Launch Control XL A")
        let offline = Self.source(10, "Launch Control XL A", offline: true)
        let second = Self.source(20, "Launch Control XL B")
        let firstKey = MIDIEndpointKey(fingerprint: first.fingerprint)
        let secondKey = MIDIEndpointKey(fingerprint: second.fingerprint)
        #expect(offline.fingerprint == first.fingerprint)
        let online = Self.bind([first, second])
        let old = try Self.token(of: 10, in: online)
        let peer = try Self.token(of: 20, in: online)
        var stream = try LaunchControlXLStream.make(backend: .experimentalMIDI1UMP)
        stream.connect(online.bindings.sources)
        #expect(stream.feedUMP(packets: [[0x3011_0100, 0]], from: old).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3011_0200, 0]], from: peer).isEmpty)

        let retired = Self.bind([offline, second], after: online.bindings)
        #expect(retired.detaches.map(\.source.token) == [old])
        #expect(retired.registrations.isEmpty)
        let retiredSharedChanged = stream.connect(retired.bindings.sources)
        #expect(!retiredSharedChanged)
        #expect(stream.snapshot.sources.map(\.key) == [Self.legacyKey, secondKey])
        let repeated = Self.bind([offline, second], after: retired.bindings)
        #expect(repeated.bindings == retired.bindings)
        #expect(repeated.detaches.isEmpty && repeated.registrations.isEmpty)
        let repeatedSharedChanged = stream.connect(repeated.bindings.sources)
        #expect(!repeatedSharedChanged)
        let returned = Self.bind([first, second], after: repeated.bindings)
        let fresh = try Self.token(of: 10, in: returned)
        #expect(fresh != old && fresh != peer)
        #expect(try Self.token(of: 20, in: returned) == peer)
        let returnedSharedChanged = stream.connect(returned.bindings.sources)
        #expect(!returnedSharedChanged)
        #expect(stream.sources == returned.bindings.sources)
        #expect(Set(stream.snapshot.sources.map(\.key)) == [Self.legacyKey, firstKey, secondKey])
        #expect(stream.feedUMP(packets: [[0x20BF_057F]], from: old).isEmpty)
        #expect(stream.droppedBatches == 1)
        #expect(stream.feedUMP(packets: [[0x3031_0300, 0]], from: fresh).isEmpty)
        let retained = stream.feedUMP(packets: [[0x3031_0400, 0]], from: peer)
        #expect(retained.map(\.event) == [.sysEx(payload: [2, 4])])

        #expect(stream.feedUMP(packets: [[0x3011_0500, 0]], from: fresh).isEmpty)
        #expect(stream.feedUMP(packets: [[0x3031_0600, 0]]).isEmpty, "A is not sharing the legacy pair")
        let completed = stream.feedUMP(packets: [[0x3031_0700, 0]], from: fresh)
        #expect(completed.map(\.event) == [.sysEx(payload: [5, 7])])
        #expect(completed.first?.input != retained.first?.input)
        #expect(completed.first?.input != LaunchControlXLStream.input)
        #expect(stream.droppedBatches == 1)
    }

    @Test func streamResetsRetainLargeDecoderBoundAndParserOverflowDiscardsToTermination() throws {
        var stream = try LaunchControlXLStream.make(backend: .experimentalMIDI1UMP)
        let full = Array(repeating: UInt32(0x10F8_0000), count: 16_383)
        for _ in 0..<2 {
            #expect(stream.feedUMP(packets: [full]).count == 16_383)
            #expect(stream.feedUMP(packets: [full + [0]]).isEmpty)
            #expect(stream.feedUMP(packets: [full]).count == 16_383)
            stream.reset()
        }
        let profile = try MIDISourceProfile.make(maximumSysExPayloadBytes: 2)
        var registry = try Self.umpRegistry(profile: profile)
        let input = MIDIInputID(1)
        #expect(try registry.feedUMP([0x3012_0102, 0, 0x3021_0300, 0], from: input).isEmpty)
        #expect(try registry.feedUMP([0x3031_0400, 0], from: input).isEmpty)
        #expect(try registry.feedUMP([0x3001_0500, 0], from: input).map(\.event) == [.sysEx(payload: [5])])
    }
}
