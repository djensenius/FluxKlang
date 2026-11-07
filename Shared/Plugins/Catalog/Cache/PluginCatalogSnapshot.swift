//
//  PluginCatalogSnapshot.swift
//  FluxKlang
//
//  The persistence model of the plugin catalog (#70): a bounded, canonical
//  snapshot of the catalog's last known state plus the stamp that says where
//  it came from. Pure values: nothing here reads or writes a file, scans,
//  asks the OS anything or instantiates a component. A snapshot is built only
//  through `make`, `capture` or `decode`, so every value that exists has been
//  validated against the same limits and initializers as a live catalog.
//

import Foundation

/// A stamp or entry field that a refusal names.
enum PluginCacheField: String, Hashable, Sendable {
    case osVersion, hostBuild, formatVersion
    case format, presence, failure, failureDetail, direction, quarantine, descriptorFlag, midiFlags
}

/// Every typed refusal of the cache codec and snapshot factories. A refusal returns
/// nothing partial and changes nothing.
enum PluginCatalogCacheError: Error, Equatable, Sendable {
    /// More bytes than `PluginCatalogCacheCodec.maximumBytes`, raised before any parsing.
    case oversized(bytes: Int, maximum: Int)
    case truncated
    case badMagic
    /// Any version other than the one this build reads and writes, older or newer.
    case unsupportedFormatVersion(found: UInt16)
    case trailingBytes(count: Int)
    case integrityFailure
    case invalidStamp(PluginCacheField)
    case generationOutOfRange(UInt64)
    case tooManyEntries(count: Int, maximum: Int)
    case tooManyDescribedEntries(count: Int, maximum: Int)
    case invalidTag(PluginCacheField, value: UInt8, index: Int)
    case invalidIdentity(index: Int)
    case invalidUTF8(index: Int)
    case invalidDescriptor(index: Int, PluginDescriptorError)
    case duplicateIdentity(PluginID)
    case entriesOutOfOrder(index: Int)
    case descriptorIdentityMismatch(PluginID)
    case installedWithoutDescriptor(PluginID)
}

/// Where a snapshot came from. The strings compare by UTF-8 bytes, never by canonical
/// equivalence, so two spellings that merely look alike are different stamps. The
/// generation is informational: generations compare by equality only (M2), so it never
/// decides whether a cache is trusted.
struct CacheStamp: Equatable, Sendable {
    let osVersion: String
    let hostBuild: String
    /// The cache format the producer wrote; 1 or more. The codec writes only its own version.
    let formatVersion: UInt16
    let generation: Generation

    init(
        osVersion: String, hostBuild: String,
        formatVersion: UInt16 = PluginCatalogCacheCodec.formatVersion, generation: Generation
    ) throws(PluginCatalogCacheError) {
        guard PluginDescriptor.isValidName(osVersion) else { throw .invalidStamp(.osVersion) }
        guard PluginDescriptor.isValidName(hostBuild) else { throw .invalidStamp(.hostBuild) }
        guard formatVersion >= 1 else { throw .invalidStamp(.formatVersion) }
        self.osVersion = osVersion
        self.hostBuild = hostBuild
        self.formatVersion = formatVersion
        self.generation = generation
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.osVersion.utf8.elementsEqual(rhs.osVersion.utf8)
            && lhs.hostBuild.utf8.elementsEqual(rhs.hostBuild.utf8)
            && lhs.formatVersion == rhs.formatVersion && lhs.generation == rhs.generation
    }
}

extension PluginIdentity {
    /// The documented total order of cache entries: format (AUv2 before AUv3), then the
    /// type, subtype and manufacturer codes as unsigned integers.
    fileprivate var cacheOrderKey: [UInt32] {
        [format == .audioUnitV2 ? 0 : 1, type.rawValue, subtype.rawValue, manufacturer.rawValue]
    }

    static func cacheOrder(_ lhs: PluginIdentity, _ rhs: PluginIdentity) -> Bool {
        lhs.cacheOrderKey.lexicographicallyPrecedes(rhs.cacheOrderKey)
    }
}

/// The last known state of a catalog: cached entries (identity, presence at capture, last
/// known descriptor, quarantine) in canonical identity order, with their stamp. A snapshot
/// claims nothing about the present: only `CacheInvalidation` decides what is trusted.
struct PluginCatalogSnapshot: Equatable, Sendable {
    let stamp: CacheStamp
    /// Ascending by `PluginIdentity.cacheOrder`, unique, and coherent (see `make`).
    private(set) var entries: [PluginCatalogEntry]

    private init(stamp: CacheStamp, entries: [PluginCatalogEntry]) {
        self.stamp = stamp
        self.entries = entries
    }

    /// Validates and canonicalises `entries`; the only way to build a snapshot from values.
    /// Refuses, in this order: too many entries, a duplicate identity, an incoherent entry
    /// (in canonical order), too many described entries. The input order never matters.
    static func make(
        entries: [PluginCatalogEntry], stamp: CacheStamp
    ) throws(PluginCatalogCacheError) -> PluginCatalogSnapshot {
        let maximumTotal = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
        guard entries.count <= maximumTotal else {
            throw .tooManyEntries(count: entries.count, maximum: maximumTotal)
        }
        let ordered = entries.sorted { PluginIdentity.cacheOrder($0.identity, $1.identity) }
        for (index, entry) in ordered.enumerated() where index > 0 && ordered[index - 1].identity == entry.identity {
            throw .duplicateIdentity(entry.identity.id)
        }
        for entry in ordered {
            if let descriptor = entry.lastKnown, descriptor.identity != entry.identity {
                throw .descriptorIdentityMismatch(entry.identity.id)
            }
            if entry.presence == .installed && entry.lastKnown == nil {
                throw .installedWithoutDescriptor(entry.identity.id)
            }
        }
        let described = ordered.count { !$0.isBare }
        guard described <= PluginCatalogLimits.entries else {
            throw .tooManyDescribedEntries(count: described, maximum: PluginCatalogLimits.entries)
        }
        return PluginCatalogSnapshot(stamp: stamp, entries: ordered)
    }

    /// Reads the catalog without changing it. The stamp carries the catalog's generation.
    static func capture(
        from catalog: PluginCatalog, osVersion: String, hostBuild: String
    ) throws(PluginCatalogCacheError) -> PluginCatalogSnapshot {
        let stamp = try CacheStamp(osVersion: osVersion, hostBuild: hostBuild, generation: catalog.generation)
        return try make(entries: Array(catalog.entries.values), stamp: stamp)
    }

    func encoded() throws(PluginCatalogCacheError) -> Data {
        try PluginCatalogCacheCodec.encode(self)
    }

    static func decode(from data: Data) throws(PluginCatalogCacheError) -> PluginCatalogSnapshot {
        try PluginCatalogCacheCodec.decode(from: data)
    }
}
