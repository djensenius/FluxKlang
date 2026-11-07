import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Cache snapshot, codec and invalidation (#70, PLG5). Helpers are nested; byte fixtures are built by
/// `Raw`, which follows the documented layout independently of the production writer.
struct PluginCatalogCacheTests {
    typealias Codec = PluginCatalogCacheCodec

    static func code(_ text: String) throws -> PluginFourCharacterCode {
        try PluginFourCharacterCode(text)
    }

    static func identity(
        _ subtype: String, manufacturer: String = "Fxkl", type: String = "aufx", format: PluginFormat = .audioUnitV2
    ) throws -> PluginIdentity {
        try PluginIdentity(
            format: format, type: code(type), subtype: code(subtype), manufacturer: code(manufacturer)
        )
    }

    static func layout(
        inputs: [Int] = [2], outputs: [Int] = [2], midiIn: Bool = false, midiOut: Bool = false
    ) throws -> PluginBusLayout {
        try PluginBusLayout(inputChannels: inputs, outputChannels: outputs, acceptsMIDI: midiIn, producesMIDI: midiOut)
    }

    static func descriptor(
        _ identity: PluginIdentity, name: String = "Plugin", manufacturerName: String = "Maker",
        version: UInt32 = 0x0001_0203, buses: PluginBusLayout? = nil
    ) throws -> PluginDescriptor {
        try PluginDescriptor(
            identity: identity, name: name, manufacturerName: manufacturerName,
            version: PluginVersion(rawValue: version), buses: buses ?? layout()
        )
    }

    /// Described by default; `described: false` leaves `lastKnown` empty.
    static func entry(
        _ identity: PluginIdentity, _ presence: PluginPresence = .installed, described: Bool = true,
        quarantine: PluginQuarantineReason? = nil
    ) throws -> PluginCatalogEntry {
        PluginCatalogEntry(
            identity: identity, presence: presence, lastKnown: described ? try descriptor(identity) : nil,
            quarantine: quarantine
        )
    }

    static func stamp(
        os osText: String = "27.0", host: String = "1A1", format: UInt16 = 1, generation: Int = 5
    ) throws -> CacheStamp {
        try CacheStamp(osVersion: osText, hostBuild: host, formatVersion: format, generation: Generation(generation))
    }

    static func snapshot(_ entries: [PluginCatalogEntry], stamp: CacheStamp? = nil) throws -> PluginCatalogSnapshot {
        try PluginCatalogSnapshot.make(entries: entries, stamp: stamp ?? Self.stamp())
    }

    /// Four printable ASCII bytes derived from `index`, so identities are distinct and valid.
    static func subtypeCode(_ index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(0x30 + (index >> (4 * (3 - $1))) & 0xF) }
    }

    static func indexedIdentity(_ index: Int, format: PluginFormat = .audioUnitV2) throws -> PluginIdentity {
        try PluginIdentity(
            format: format, type: code("aufx"),
            subtype: #require(PluginFourCharacterCode(rawValue: subtypeCode(index))), manufacturer: code("Fxkl")
        )
    }

    /// An entry that is not bare and carries no descriptor: the smallest ordinary entry.
    static func plainEntry(_ index: Int) throws -> PluginCatalogEntry {
        try entry(indexedIdentity(index), .missing, described: false)
    }

    static func bareEntry(_ index: Int) throws -> PluginCatalogEntry {
        try entry(indexedIdentity(index), .needsRescan, described: false, quarantine: .probeCrashed)
    }

    /// Every field at its limit, so the encoding has the most bytes one described entry can have.
    static func largestDescribedEntry(_ index: Int) throws -> PluginCatalogEntry {
        let identity = try indexedIdentity(index)
        let name = String(repeating: "N", count: PluginCatalogLimits.nameBytes)
        let buses = try layout(
            inputs: Array(repeating: PluginCatalogLimits.channelsPerBus, count: PluginCatalogLimits.busesPerDirection),
            outputs: Array(repeating: 1, count: PluginCatalogLimits.busesPerDirection), midiIn: true, midiOut: true
        )
        return PluginCatalogEntry(
            identity: identity, presence: .failed(.invalidMetadata(.invalidChannelCount(.output, bus: -3, count: 99))),
            lastKnown: try descriptor(identity, name: name, manufacturerName: name, buses: buses),
            quarantine: .probeTimedOut
        )
    }

    static func largestBareEntry(_ index: Int) throws -> PluginCatalogEntry {
        PluginCatalogEntry(
            identity: try indexedIdentity(index),
            presence: .failed(.invalidMetadata(.invalidChannelCount(.output, bus: -3, count: 99))),
            lastKnown: nil, quarantine: .probeTimedOut
        )
    }

    /// One catalog exercising every presence kind, built only through the public catalog API.
    static func busyCatalog() throws -> PluginCatalog {
        var catalog = PluginCatalog()
        let described = try [identity("Verb"), identity("Echo")]
        let failed = try identity("Fail")
        let crashed = try identity("Boom")
        let entries = try described.map { PluginScanEntry(identity: $0, outcome: .described(try descriptor($0))) }
            + [PluginScanEntry(identity: failed, outcome: .failed(.validationFailed)),
               PluginScanEntry(identity: crashed, outcome: .probeCrashed)]
        _ = try catalog.apply(PluginScanReport(entries: entries), for: catalog.request(depth: .instantiatingProbe))
        return catalog
    }
}
