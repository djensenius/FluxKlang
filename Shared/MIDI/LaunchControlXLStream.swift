//
//  LaunchControlXLStream.swift
//  FluxKlang
//

/// The Launch Control XL as the only source of a `MIDISourceRegistry` (#80): one bounded parser and one
/// `MIDI1PerformanceState` under the surface's profile, so running status, SysEx and half messages carry across
/// packets. Every matched endpoint feeds this one logical source; endpoint identity and continuity belong to #81.
struct LaunchControlXLStream: Sendable {
    /// CoreMIDI's `MIDIPacket.length` is a `UInt16`, so no real packet is longer; a longer one is refused whole.
    static let maximumPacketBytes = Int(UInt16.max)
    static let input = MIDIInputID(0)
    private static let key = MIDIEndpointKey(fingerprint: 0)

    private var registry: MIDISourceRegistry

    var snapshot: MIDISourceRegistrySnapshot { registry.snapshot }

    static func make(
        profile: MIDISourceProfile = LaunchControlXLMapping.sourceProfile
    ) throws(MIDISourceRefusal) -> LaunchControlXLStream {
        var registry = try MIDISourceRegistry.make(maximumSources: 1, maximumFeedBytes: maximumPacketBytes)
        try registry.register(input, key: key, profile: profile)
        return LaunchControlXLStream(registry: registry)
    }

    private init(registry: MIDISourceRegistry) {
        self.registry = registry
    }

    /// Feeds each packet in order and concatenates the outputs. A packet over `maximumPacketBytes` adds nothing
    /// and leaves the parser and state as they were.
    mutating func feed(packets: [[UInt8]]) -> [MIDISourceOutput] {
        var outputs: [MIDISourceOutput] = []
        for packet in packets {
            do throws(MIDISourceRefusal) {
                outputs += try registry.feed(packet, from: Self.input)
            } catch {
                continue
            }
        }
        return outputs
    }

    /// Starts the source fresh through `MIDISourceRegistry.resetSource`: the half message, running status, open
    /// SysEx and state are dropped. The released notes are discarded; the surface maps only control changes.
    mutating func reset() {
        // `input` is registered by `make` and never detached, so this cannot be refused.
        _ = try? registry.resetSource(Self.input)
    }
}
