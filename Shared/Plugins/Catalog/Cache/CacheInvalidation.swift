//
//  CacheInvalidation.swift
//  FluxKlang
//
//  Decides what a decoded catalog snapshot is worth under the CURRENT stamp
//  (#70). Any mismatch makes every entry `needsRescan`: no entry is dropped, no
//  identity or last-known descriptor is replaced, and quarantine is never
//  released, so a stale cache can only withhold trust, never grant it or erase
//  evidence. A stamp mismatch is not a decode error. Stamps compare byte-exactly.
//  The capture generation never takes part: generations compare by equality only
//  (M2), so "regressed" has no meaning and is deliberately not modelled.
//

import Foundation

/// Why a cache is not trusted, in the fixed order of this declaration.
enum CacheStaleReason: Int, Hashable, Sendable, CaseIterable {
    case osChanged
    case hostChanged
    /// The producer's cache format differs from the one the host currently expects.
    case formatChanged
}

enum CacheEntryTrust: Hashable, Sendable {
    case trusted
    /// Every reason that applies, each once, in `CacheStaleReason` declaration order.
    case needsRescan([CacheStaleReason])
}

/// One cached entry after invalidation. `entry.presence` is the presence it may be restored with.
struct PluginRestoredEntry: Hashable, Sendable {
    let entry: PluginCatalogEntry
    let trust: CacheEntryTrust
}

enum CacheInvalidation {
    /// The reasons `cached` is stale under `current`, in declaration order; empty when the stamps agree.
    static func staleReasons(cached: CacheStamp, current: CacheStamp) -> [CacheStaleReason] {
        var reasons: [CacheStaleReason] = []
        if !cached.osVersion.utf8.elementsEqual(current.osVersion.utf8) { reasons.append(.osChanged) }
        if !cached.hostBuild.utf8.elementsEqual(current.hostBuild.utf8) { reasons.append(.hostChanged) }
        if cached.formatVersion != current.formatVersion { reasons.append(.formatChanged) }
        return reasons
    }

    static func restore(_ snapshot: PluginCatalogSnapshot, current: CacheStamp) -> PluginCatalogRestoration {
        PluginCatalogRestoration(snapshot, reasons: staleReasons(cached: snapshot.stamp, current: current))
    }
}

/// The outcome of restoring a snapshot: every cached entry, in canonical identity order, with
/// its trust. A trusted entry keeps the presence it was captured with; a stale entry becomes
/// `needsRescan` and keeps its identity, last-known descriptor and quarantine unchanged.
struct PluginCatalogRestoration: Equatable, Sendable {
    /// The generation recorded at capture, for information only.
    let cachedGeneration: Generation
    /// Why the whole cache is stale; empty when it is trusted (also for a cache with no entries).
    let staleReasons: [CacheStaleReason]
    private(set) var entries: [PluginRestoredEntry]

    fileprivate init(_ snapshot: PluginCatalogSnapshot, reasons: [CacheStaleReason]) {
        cachedGeneration = snapshot.stamp.generation
        staleReasons = reasons
        let trust: CacheEntryTrust = reasons.isEmpty ? .trusted : .needsRescan(reasons)
        entries = snapshot.entries.map { cached in
            var entry = cached
            if !reasons.isEmpty { entry.presence = .needsRescan }
            return PluginRestoredEntry(entry: entry, trust: trust)
        }
    }

    var isTrusted: Bool {
        staleReasons.isEmpty
    }

    /// The cached quarantine as evidence for `PluginCatalog.recordQuarantine`, in canonical order and in
    /// batches of at most `PluginCatalogLimits.entries` (the size one call accepts). That is the only
    /// way the current catalog API can adopt cached state; adopting it keeps each entry quarantined.
    var quarantineEvidenceBatches: [[PluginQuarantineEvidence]] {
        let evidence = entries.compactMap { restored in
            restored.entry.quarantine.map { PluginQuarantineEvidence(identity: restored.entry.identity, reason: $0) }
        }
        return stride(from: 0, to: evidence.count, by: PluginCatalogLimits.entries).map {
            Array(evidence[$0..<min($0 + PluginCatalogLimits.entries, evidence.count)])
        }
    }
}
