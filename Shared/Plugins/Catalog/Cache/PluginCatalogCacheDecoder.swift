//
//  PluginCatalogCacheDecoder.swift
//  FluxKlang
//
//  The reader of the plugin catalog cache (#70). The byte limit is checked
//  before anything is parsed, then the frame (magic, version, declared length,
//  trailing bytes, integrity) before the payload, then the payload entry by
//  entry in wire order. Every decoded value goes through the existing identity,
//  descriptor and bus-layout initializers and then `PluginCatalogSnapshot.make`,
//  so nothing decoded bypasses a validation a live catalog applies. A refusal
//  returns only the error: there is no partial result.
//

import Foundation

/// Reads fixed-width big-endian integers and length-prefixed strings; any read past the end is `truncated`.
/// Decoded `PluginDescriptorError` payloads (bus counts, channel counts) are arbitrary 64-bit values: they
/// are not validated, but they round-trip exactly.
struct CacheReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ count: Int) throws(PluginCatalogCacheError) -> ArraySlice<UInt8> {
        guard count <= remaining else { throw .truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func integer<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws(PluginCatalogCacheError) -> T {
        try take(T.bitWidth / 8).reduce(T(0)) { $0 << 8 | T($1) }
    }

    /// A signed 64-bit field; `Int` is 64 bits wide on every platform the app supports.
    mutating func signed() throws(PluginCatalogCacheError) -> Int {
        Int(truncatingIfNeeded: Int64(bitPattern: try integer(UInt64.self)))
    }

    /// `nil` when the bytes are not well-formed UTF-8.
    mutating func string() throws(PluginCatalogCacheError) -> String? {
        let length = Int(try integer(UInt16.self))
        return String(validating: try take(length), as: UTF8.self)
    }

    mutating func tag(_ field: PluginCacheField, index: Int, cases: Int) throws(PluginCatalogCacheError) -> UInt8 {
        let value = try integer(UInt8.self)
        guard Int(value) < cases else { throw .invalidTag(field, value: value, index: index) }
        return value
    }
}

extension PluginCatalogCacheCodec {
    static func decode(from data: Data) throws(PluginCatalogCacheError) -> PluginCatalogSnapshot {
        guard data.count <= maximumBytes else { throw .oversized(bytes: data.count, maximum: maximumBytes) }
        let bytes = [UInt8](data)
        var header = CacheReader(bytes)
        guard try header.take(magic.count).elementsEqual(magic) else { throw .badMagic }
        let version = try header.integer(UInt16.self)
        guard version == formatVersion else { throw .unsupportedFormatVersion(found: version) }
        let length = Int(try header.integer(UInt32.self))
        let total = headerBytes + length + trailerBytes
        guard total <= maximumBytes else { throw .oversized(bytes: total, maximum: maximumBytes) }
        guard bytes.count >= total else { throw .truncated }
        guard bytes.count == total else { throw .trailingBytes(count: bytes.count - total) }
        var trailer = CacheReader(Array(bytes[(total - trailerBytes)...]))
        guard try checksum(bytes[..<(total - trailerBytes)]) == trailer.integer(UInt64.self) else {
            throw .integrityFailure
        }
        return try payload(CacheReader(Array(bytes[headerBytes..<(total - trailerBytes)])), version: version)
    }

    private static func payload(
        _ input: CacheReader, version: UInt16
    ) throws(PluginCatalogCacheError) -> PluginCatalogSnapshot {
        var reader = input
        let stamp = try readStamp(&reader, version: version)
        let count = Int(try reader.integer(UInt32.self))
        let maximumTotal = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
        guard count <= maximumTotal else { throw .tooManyEntries(count: count, maximum: maximumTotal) }
        var entries: [PluginCatalogEntry] = []
        for index in 0..<count {
            let entry = try readEntry(&reader, index: index)
            if let previous = entries.last {
                guard previous.identity != entry.identity else { throw .duplicateIdentity(entry.identity.id) }
                guard PluginIdentity.cacheOrder(previous.identity, entry.identity) else {
                    throw .entriesOutOfOrder(index: index)
                }
            }
            entries.append(entry)
        }
        guard reader.remaining == 0 else { throw .trailingBytes(count: reader.remaining) }
        return try PluginCatalogSnapshot.make(entries: entries, stamp: stamp)
    }

    private static func readStamp(
        _ reader: inout CacheReader, version: UInt16
    ) throws(PluginCatalogCacheError) -> CacheStamp {
        guard let osVersion = try reader.string(), PluginDescriptor.isValidName(osVersion) else {
            throw .invalidStamp(.osVersion)
        }
        guard let hostBuild = try reader.string(), PluginDescriptor.isValidName(hostBuild) else {
            throw .invalidStamp(.hostBuild)
        }
        let raw = try reader.integer(UInt64.self)
        let generation: Generation
        do {
            generation = try Generation(Int(clamping: raw))
        } catch {
            throw .generationOutOfRange(raw)
        }
        return try CacheStamp(
            osVersion: osVersion, hostBuild: hostBuild, formatVersion: version, generation: generation
        )
    }

    private static func readEntry(
        _ reader: inout CacheReader, index: Int
    ) throws(PluginCatalogCacheError) -> PluginCatalogEntry {
        let identity = try readIdentity(&reader, index: index)
        let presence = try readPresence(&reader, index: index)
        let quarantine: PluginQuarantineReason?
        switch try reader.tag(.quarantine, index: index, cases: 3) {
        case 0: quarantine = nil
        case 1: quarantine = .probeCrashed
        default: quarantine = .probeTimedOut
        }
        var descriptor: PluginDescriptor?
        if try reader.tag(.descriptorFlag, index: index, cases: 2) == 1 {
            descriptor = try readDescriptor(&reader, identity: identity, index: index)
        }
        return PluginCatalogEntry(identity: identity, presence: presence, lastKnown: descriptor, quarantine: quarantine)
    }

    private static func readIdentity(
        _ reader: inout CacheReader, index: Int
    ) throws(PluginCatalogCacheError) -> PluginIdentity {
        let format: PluginFormat = try reader.tag(.format, index: index, cases: 2) == 0 ? .audioUnitV2 : .audioUnitV3
        let codes = [try reader.integer(UInt32.self), try reader.integer(UInt32.self), try reader.integer(UInt32.self)]
        guard let type = PluginFourCharacterCode(rawValue: codes[0]),
              let subtype = PluginFourCharacterCode(rawValue: codes[1]),
              let manufacturer = PluginFourCharacterCode(rawValue: codes[2]) else {
            throw .invalidIdentity(index: index)
        }
        do {
            return try PluginIdentity(format: format, type: type, subtype: subtype, manufacturer: manufacturer)
        } catch {
            throw .invalidIdentity(index: index)
        }
    }

    private static func readPresence(
        _ reader: inout CacheReader, index: Int
    ) throws(PluginCatalogCacheError) -> PluginPresence {
        switch try reader.tag(.presence, index: index, cases: 4) {
        case 0: return .installed
        case 1: return .missing
        case 2: return .failed(try readFailure(&reader, index: index))
        default: return .needsRescan
        }
    }

    private static func readFailure(
        _ reader: inout CacheReader, index: Int
    ) throws(PluginCatalogCacheError) -> PluginScanFailure {
        switch try reader.tag(.failure, index: index, cases: 3) {
        case 0: return .metadataUnavailable
        case 1: return .invalidMetadata(try readDescriptorError(&reader, index: index))
        default: return .validationFailed
        }
    }

    private static func readDescriptorError(
        _ reader: inout CacheReader, index: Int
    ) throws(PluginCatalogCacheError) -> PluginDescriptorError {
        switch try reader.tag(.failureDetail, index: index, cases: 4) {
        case 0: return .invalidName
        case 1: return .invalidManufacturerName
        case 2:
            let direction = try readDirection(&reader, index: index)
            return .tooManyBuses(direction, count: try reader.signed())
        default:
            let direction = try readDirection(&reader, index: index)
            let bus = try reader.signed()
            return .invalidChannelCount(direction, bus: bus, count: try reader.signed())
        }
    }

    private static func readDirection(
        _ reader: inout CacheReader, index: Int
    ) throws(PluginCatalogCacheError) -> PluginBusDirection {
        try reader.tag(.direction, index: index, cases: 2) == 0 ? .input : .output
    }

    private static func readDescriptor(
        _ reader: inout CacheReader, identity: PluginIdentity, index: Int
    ) throws(PluginCatalogCacheError) -> PluginDescriptor {
        guard let name = try reader.string(), let manufacturerName = try reader.string() else {
            throw .invalidUTF8(index: index)
        }
        let version = PluginVersion(rawValue: try reader.integer(UInt32.self))
        let inputs = try readChannels(&reader)
        let outputs = try readChannels(&reader)
        let flags = try reader.tag(.midiFlags, index: index, cases: 4)
        do throws(PluginDescriptorError) {
            let buses = try PluginBusLayout(
                inputChannels: inputs, outputChannels: outputs,
                acceptsMIDI: flags & 1 != 0, producesMIDI: flags & 2 != 0
            )
            return try PluginDescriptor(
                identity: identity, name: name, manufacturerName: manufacturerName, version: version, buses: buses
            )
        } catch {
            throw .invalidDescriptor(index: index, error)
        }
    }

    private static func readChannels(_ reader: inout CacheReader) throws(PluginCatalogCacheError) -> [Int] {
        let count = Int(try reader.integer(UInt8.self))
        return try reader.take(count).map(Int.init)
    }
}
