import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginCatalogCacheTests {
    static func mixedSnapshot() throws -> PluginCatalogSnapshot {
        let crashed = try entry(identity("Boom"), .needsRescan, described: false, quarantine: .probeCrashed)
        let failed = try entry(identity("Fail"), .failed(.validationFailed), described: false)
        let missing = try entry(identity("Gone"), .missing)
        let installed = try entry(identity("Verb"), .installed, quarantine: .probeTimedOut)
        return try snapshot([installed, missing, failed, crashed])
    }

    @Test func matchingStampsRestoreEveryEntryTrustedWithItsCapturedPresence() throws {
        let cached = try Self.mixedSnapshot()
        let restored = CacheInvalidation.restore(cached, current: try Self.stamp())
        #expect(restored.isTrusted && restored.staleReasons.isEmpty)
        #expect(restored.entries.map(\.entry) == cached.entries)
        #expect(restored.entries.allSatisfy { $0.trust == .trusted })
    }

    @Test func aDifferentOSVersionAloneMakesEveryEntryNeedRescanForOSChanged() throws {
        let restored = CacheInvalidation.restore(try Self.mixedSnapshot(), current: try Self.stamp(os: "27.1"))
        #expect(restored.staleReasons == [.osChanged] && !restored.isTrusted)
        #expect(restored.entries.allSatisfy { $0.trust == .needsRescan([.osChanged]) })
        #expect(restored.entries.allSatisfy { $0.entry.presence == .needsRescan })
    }

    @Test func aDifferentHostBuildAloneMakesEveryEntryNeedRescanForHostChanged() throws {
        let restored = CacheInvalidation.restore(try Self.mixedSnapshot(), current: try Self.stamp(host: "1A2"))
        #expect(restored.staleReasons == [.hostChanged])
        #expect(restored.entries.allSatisfy { $0.trust == .needsRescan([.hostChanged]) })
    }

    @Test func aDifferentFormatVersionAloneMakesEveryEntryNeedRescanForFormatChanged() throws {
        let restored = CacheInvalidation.restore(try Self.mixedSnapshot(), current: try Self.stamp(format: 2))
        #expect(restored.staleReasons == [.formatChanged])
        #expect(restored.entries.allSatisfy { $0.trust == .needsRescan([.formatChanged]) })
    }

    @Test func everyReasonThatAppliesIsListedOnceInDeclarationOrder() throws {
        let current = try Self.stamp(os: "28", host: "2B", format: 3)
        let reasons = CacheInvalidation.staleReasons(cached: try Self.stamp(), current: current)
        #expect(reasons == [.osChanged, .hostChanged, .formatChanged])
        let moved = try Self.stamp(host: "x", format: 2)
        let two = CacheInvalidation.staleReasons(cached: try Self.stamp(), current: moved)
        #expect(two == [.hostChanged, .formatChanged])
        let restored = CacheInvalidation.restore(try Self.mixedSnapshot(), current: current)
        #expect(restored.entries.allSatisfy { $0.trust == .needsRescan([.osChanged, .hostChanged, .formatChanged]) })
    }

    @Test func aDifferentGenerationAloneNeverMakesTheCacheStale() throws {
        let cached = try Self.mixedSnapshot()
        let five = try Generation(5)
        for generation in [1, 4, 6, 1_000] {
            let restored = CacheInvalidation.restore(cached, current: try Self.stamp(generation: generation))
            #expect(restored.isTrusted)
            #expect(restored.cachedGeneration == five)
        }
    }

    @Test func stampsCompareByUTF8BytesNotCanonicalEquivalence() throws {
        let composed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        let cached = try Self.stamp(os: composed)
        let current = try Self.stamp(os: decomposed)
        #expect(cached != current)
        #expect(CacheInvalidation.staleReasons(cached: cached, current: current) == [.osChanged])
        #expect(CacheInvalidation.staleReasons(cached: cached, current: cached).isEmpty)
    }

    @Test func aStaleRestoreKeepsIdentityLastKnownAndQuarantineAndDropsFailureDetail() throws {
        let cached = try Self.mixedSnapshot()
        let restored = CacheInvalidation.restore(cached, current: try Self.stamp(os: "28"))
        #expect(restored.entries.count == cached.entries.count)
        for (before, after) in zip(cached.entries, restored.entries.map(\.entry)) {
            #expect(after.identity == before.identity)
            #expect(after.lastKnown == before.lastKnown)
            #expect(after.quarantine == before.quarantine)
            #expect(after.presence == .needsRescan)
        }
        #expect(cached.entries.contains { $0.presence == .failed(.validationFailed) })
        #expect(restored.entries.contains { $0.entry.quarantine == .probeTimedOut && $0.entry.lastKnown != nil })
    }

    @Test func restoringNeverMutatesTheSnapshotAndIsRepeatable() throws {
        let cached = try Self.mixedSnapshot()
        let before = try cached.encoded()
        let stale = try Self.stamp(os: "28")
        let first = CacheInvalidation.restore(cached, current: stale)
        let second = CacheInvalidation.restore(cached, current: stale)
        #expect(first == second)
        #expect(try cached.encoded() == before)
        #expect(cached.entries.contains { $0.presence == .installed })
    }

    @Test func restoredEntriesFollowCanonicalOrderWhateverTheInputOrder() throws {
        let entries = try [
            Self.entry(Self.identity("Zzzz", format: .audioUnitV3)), Self.entry(Self.identity("Bbbb")),
            Self.entry(Self.identity("Aaaa", type: "aumu")), Self.entry(Self.identity("Aaaa"))
        ]
        let forward = try Self.snapshot(entries)
        let backward = try Self.snapshot(entries.reversed())
        #expect(forward == backward)
        let order = CacheInvalidation.restore(forward, current: try Self.stamp()).entries.map(\.entry.identity)
        #expect(order == [
            try Self.identity("Aaaa"), try Self.identity("Bbbb"), try Self.identity("Aaaa", type: "aumu"),
            try Self.identity("Zzzz", format: .audioUnitV3)
        ])
        #expect(try forward.encoded() == backward.encoded())
    }

    @Test func anEmptyCacheIsTrustedWhenTheStampsAgreeAndStaleOtherwise() throws {
        let empty = try Self.snapshot([])
        #expect(CacheInvalidation.restore(empty, current: try Self.stamp()).isTrusted)
        let stale = CacheInvalidation.restore(empty, current: try Self.stamp(host: "x"))
        #expect(!stale.isTrusted && stale.entries.isEmpty && stale.staleReasons == [.hostChanged])
    }

    @Test func quarantineEvidenceKeepsEveryCachedQuarantineInCanonicalOrder() throws {
        let restored = CacheInvalidation.restore(try Self.mixedSnapshot(), current: try Self.stamp(os: "28"))
        let batches = restored.quarantineEvidenceBatches
        #expect(batches.count == 1)
        #expect(batches[0] == [
            PluginQuarantineEvidence(identity: try Self.identity("Boom"), reason: .probeCrashed),
            PluginQuarantineEvidence(identity: try Self.identity("Verb"), reason: .probeTimedOut)
        ])
        let plain = try Self.snapshot([Self.entry(Self.identity("Verb"))])
        let none = CacheInvalidation.restore(plain, current: try Self.stamp())
        #expect(none.quarantineEvidenceBatches.isEmpty)
    }

    @Test func quarantineEvidenceIsBatchedAtTheCatalogLimitAtNAndNPlusOne() throws {
        func batchSizes(_ count: Int) throws -> [Int] {
            let snapshot = try Self.snapshot(Self.bareEntries(0..<count))
            return CacheInvalidation.restore(snapshot, current: try Self.stamp()).quarantineEvidenceBatches.map(\.count)
        }
        #expect(try batchSizes(4_096) == [4_096])
        #expect(try batchSizes(4_097) == [4_096, 1])
        #expect(try batchSizes(4_352) == [4_096, 256])
    }

    @Test func aCatalogAdoptsTheCachedQuarantineAndKeepsItQuarantinedAndNeedingRescan() throws {
        let restored = CacheInvalidation.restore(try Self.mixedSnapshot(), current: try Self.stamp())
        var catalog = PluginCatalog()
        for batch in restored.quarantineEvidenceBatches {
            _ = try catalog.recordQuarantine(batch)
        }
        let boom = try Self.identity("Boom")
        #expect(catalog.entries[boom.id]?.quarantine == .probeCrashed)
        #expect(catalog.entries[boom.id]?.presence == .needsRescan)
        let verb = try Self.identity("Verb")
        #expect(catalog.entries[verb.id]?.quarantine == .probeTimedOut)
        #expect(catalog.entries.count == 2)
    }

    @Test func aFullCacheOfQuarantinedEntriesIsAdoptedInTwoBatches() throws {
        let full = try Self.snapshot(Self.bareEntries(0..<Self.totalLimit))
        let restored = CacheInvalidation.restore(full, current: try Self.stamp())
        #expect(restored.quarantineEvidenceBatches.count == 2)
        var catalog = PluginCatalog()
        for batch in restored.quarantineEvidenceBatches {
            _ = try catalog.recordQuarantine(batch)
        }
        #expect(catalog.entries.count == 4_352)
        #expect(catalog.entries.values.allSatisfy { $0.quarantine == .probeCrashed })
    }

    @Test func aCapturedCatalogRestoresTrustedAndRoundTripsThroughBytes() throws {
        let catalog = try Self.busyCatalog()
        let captured = try PluginCatalogSnapshot.capture(from: catalog, osVersion: "27.0", hostBuild: "1A1")
        let decoded = try PluginCatalogSnapshot.decode(from: captured.encoded())
        #expect(decoded == captured)
        #expect(decoded.entries.count == catalog.entries.count)
        let restored = CacheInvalidation.restore(decoded, current: decoded.stamp)
        #expect(restored.isTrusted)
        #expect(restored.cachedGeneration == catalog.generation)
    }
}
