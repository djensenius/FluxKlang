//
//  PluginDescriptor.swift
//  FluxKlang
//
//  The metadata a scan reports for one component: names, version and bus
//  layout. Every value is "reported" by the component or the OS; none of it is
//  measured, and none of it establishes that the plugin can be loaded or run.
//

import Foundation

/// Catalog resource policy, not plugin or engine capacities.
enum PluginCatalogLimits {
    /// Catalog entries, including missing, failed and quarantined ones.
    static let entries = 4_096
    /// Extra bare quarantined entries allowed above `entries`, so crash and
    /// hang evidence is never dropped at the cap; beyond it recording refuses.
    static let quarantineHeadroom = 256
    static let nameBytes = 256
    static let busesPerDirection = 64
    static let channelsPerBus = 64
}

enum PluginDescriptorError: Error, Hashable, Sendable {
    case invalidName
    case invalidManufacturerName
    case tooManyBuses(PluginBusDirection, count: Int)
    case invalidChannelCount(PluginBusDirection, bus: Int, count: Int)
}

enum PluginBusDirection: String, Hashable, Sendable {
    case input, output
}

/// Reported default channel counts per audio bus, plus MIDI event ports.
struct PluginBusLayout: Hashable, Sendable {
    let inputChannels: [Int]
    let outputChannels: [Int]
    let acceptsMIDI: Bool
    let producesMIDI: Bool

    init(
        inputChannels: [Int], outputChannels: [Int], acceptsMIDI: Bool = false, producesMIDI: Bool = false
    ) throws(PluginDescriptorError) {
        try Self.check(inputChannels, .input)
        try Self.check(outputChannels, .output)
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.acceptsMIDI = acceptsMIDI
        self.producesMIDI = producesMIDI
    }

    private static func check(_ channels: [Int], _ direction: PluginBusDirection) throws(PluginDescriptorError) {
        guard channels.count <= PluginCatalogLimits.busesPerDirection else {
            throw .tooManyBuses(direction, count: channels.count)
        }
        for (bus, count) in channels.enumerated() where !(1...PluginCatalogLimits.channelsPerBus).contains(count) {
            throw .invalidChannelCount(direction, bus: bus, count: count)
        }
    }
}

/// One component as last described by a scan.
struct PluginDescriptor: Hashable, Sendable {
    let identity: PluginIdentity
    let name: String
    let manufacturerName: String
    let version: PluginVersion
    let buses: PluginBusLayout

    init(
        identity: PluginIdentity, name: String, manufacturerName: String,
        version: PluginVersion, buses: PluginBusLayout
    ) throws(PluginDescriptorError) {
        guard Self.isValidName(name) else { throw .invalidName }
        guard Self.isValidName(manufacturerName) else { throw .invalidManufacturerName }
        self.identity = identity
        self.name = name
        self.manufacturerName = manufacturerName
        self.version = version
        self.buses = buses
    }

    var id: PluginID { identity.id }

    /// Bounded, not blank, and free of control (Cc) and format (Cf) scalars such
    /// as NUL, line breaks and bidirectional overrides that would disguise a name.
    static func isValidName(_ name: String) -> Bool {
        name.utf8.count <= PluginCatalogLimits.nameBytes
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
    }
}
