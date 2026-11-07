//
//  PluginCatalogCacheCodec.swift
//  FluxKlang
//
//  The byte layout and the writer of the plugin catalog cache (#70). A small
//  big-endian binary format rather than `Codable`: output is a pure function of
//  the snapshot (no key order, number formatting or Unicode normalisation),
//  every string is a length-prefixed UTF-8 byte string bounded in bytes, there
//  is no floating point, and the total size has an exact bound. The reader is in
//  PluginCatalogCacheDecoder.swift.
//
//  header   "FXPC" | formatVersion u16 | payloadLength u32
//  payload  osVersion, hostBuild (u16 length + UTF-8) | generation u64 | entryCount u32 | entry*
//  entry    format u8 | type u32 | subtype u32 | manufacturer u32 | presence | quarantine u8 | descriptor
//  trailer  FNV-1a 64 of header and payload
//
//  The trailer detects accidental corruption. It is not a signature and offers no
//  protection against deliberate tampering.
//

import Foundation

enum PluginCatalogCacheCodec {
    static let magic: [UInt8] = [0x46, 0x58, 0x50, 0x43]
    static let formatVersion: UInt16 = 1
    static let headerBytes = 10
    static let trailerBytes = 8

    /// Exact worst case: the stamp at its string limits, then the most entries a catalog can
    /// hold with the most bytes each (4,096 described entries plus the bare quarantine headroom).
    static let maximumBytes = headerBytes + maximumStampBytes + 4 + trailerBytes
        + PluginCatalogLimits.entries * maximumDescribedEntryBytes
        + PluginCatalogLimits.quarantineHeadroom * maximumBareEntryBytes

    private static let maximumStampBytes = 2 * (2 + PluginCatalogLimits.nameBytes) + 8
    /// Identity 13, presence 20 (failed, invalid channel count), quarantine 1, descriptor flag 1.
    private static let maximumBareEntryBytes = 13 + 20 + 1 + 1
    private static let maximumDescribedEntryBytes = maximumBareEntryBytes
        + 2 * (2 + PluginCatalogLimits.nameBytes) + 4 + 2 * (1 + PluginCatalogLimits.busesPerDirection) + 1

    /// 64-bit FNV-1a. The wrapping multiply is the algorithm, not an overflow.
    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func encode(_ snapshot: PluginCatalogSnapshot) throws(PluginCatalogCacheError) -> Data {
        let stamp = snapshot.stamp
        guard stamp.formatVersion == formatVersion else {
            throw .unsupportedFormatVersion(found: stamp.formatVersion)
        }
        var payload = CacheWriter()
        payload.string(stamp.osVersion)
        payload.string(stamp.hostBuild)
        payload.integer(UInt64(stamp.generation.value))
        payload.integer(UInt32(snapshot.entries.count))
        for entry in snapshot.entries { payload.entry(entry) }
        var frame = CacheWriter()
        frame.append(contentsOf: magic)
        frame.integer(formatVersion)
        frame.integer(UInt32(payload.bytes.count))
        frame.append(contentsOf: payload.bytes)
        frame.integer(checksum(frame.bytes))
        return Data(frame.bytes)
    }
}

/// Appends fixed-width big-endian integers and length-prefixed strings.
struct CacheWriter {
    private(set) var bytes: [UInt8] = []

    mutating func append(contentsOf more: [UInt8]) {
        bytes += more
    }

    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    /// Strings are validated (at most 256 bytes) before they reach a snapshot.
    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        integer(UInt16(utf8.count))
        bytes += utf8
    }

    mutating func entry(_ entry: PluginCatalogEntry) {
        let identity = entry.identity
        integer(UInt8(identity.format == .audioUnitV2 ? 0 : 1))
        integer(identity.type.rawValue)
        integer(identity.subtype.rawValue)
        integer(identity.manufacturer.rawValue)
        presence(entry.presence)
        switch entry.quarantine {
        case nil: integer(UInt8(0))
        case .probeCrashed: integer(UInt8(1))
        case .probeTimedOut: integer(UInt8(2))
        }
        guard let descriptor = entry.lastKnown else { return integer(UInt8(0)) }
        integer(UInt8(1))
        string(descriptor.name)
        string(descriptor.manufacturerName)
        integer(descriptor.version.rawValue)
        channels(descriptor.buses.inputChannels)
        channels(descriptor.buses.outputChannels)
        integer(UInt8((descriptor.buses.acceptsMIDI ? 1 : 0) | (descriptor.buses.producesMIDI ? 2 : 0)))
    }

    /// Bus counts and channel counts were validated (at most 64) by `PluginBusLayout`.
    private mutating func channels(_ channels: [Int]) {
        integer(UInt8(channels.count))
        for count in channels { integer(UInt8(count)) }
    }

    private mutating func presence(_ presence: PluginPresence) {
        switch presence {
        case .installed: integer(UInt8(0))
        case .missing: integer(UInt8(1))
        case .failed(let failure):
            integer(UInt8(2))
            self.failure(failure)
        case .needsRescan: integer(UInt8(3))
        }
    }

    private mutating func failure(_ failure: PluginScanFailure) {
        switch failure {
        case .metadataUnavailable: integer(UInt8(0))
        case .invalidMetadata(let error):
            integer(UInt8(1))
            descriptorError(error)
        case .validationFailed: integer(UInt8(2))
        }
    }

    private mutating func descriptorError(_ error: PluginDescriptorError) {
        switch error {
        case .invalidName: integer(UInt8(0))
        case .invalidManufacturerName: integer(UInt8(1))
        case .tooManyBuses(let direction, let count):
            integer(UInt8(2))
            integer(UInt8(direction == .input ? 0 : 1))
            integer(Int64(count))
        case .invalidChannelCount(let direction, let bus, let count):
            integer(UInt8(3))
            integer(UInt8(direction == .input ? 0 : 1))
            integer(Int64(bus))
            integer(Int64(count))
        }
    }
}
