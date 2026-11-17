//
//  LaunchControlXLStream.swift
//  FluxKlang
//

/// The Launch Control XL on a `MIDISourceRegistry` (#80, #81): one bounded parser and one `MIDI1PerformanceState` per
/// source under the surface's profile, so running status, SysEx and half messages carry across packets of one source
/// and never across sources. Each resolved connection (`MIDIConnectedSource.endpoint` non-nil) gets its own source,
/// registered when it connects and detached when it goes, so a replug always starts fresh. Unresolved connections,
/// and batches without a token, share the legacy source `input`, keyed by fingerprint 0, as every endpoint did before.
struct LaunchControlXLStream: Sendable {
    /// CoreMIDI's `MIDIPacket.length` is a `UInt16`, so no real packet is longer; a longer one is refused whole.
    static let maximumPacketBytes = Int(UInt16.max)
    /// The registry default: the legacy source plus 31 identified units, more surfaces than one person connects at
    /// once, while bounding the parsers (and their SysEx buffers) one stream can hold. A unit refused past it shares
    /// the legacy source and is reported unresolved; it is never dropped.
    static let maximumSources = MIDISourceRegistry.defaultMaximumSources
    /// The legacy source, registered by `make` and never detached.
    static let input = MIDIInputID(0)
    private static let key = MIDIEndpointKey(fingerprint: 0)

    /// Where a connection's batches go, and the key it asked for, so a report repeating it changes nothing.
    private struct Route: Sendable {
        let requested: MIDIEndpointKey?
        let input: MIDIInputID
    }

    private var registry: MIDISourceRegistry
    private let profile: MIDISourceProfile
    private var routes: [MIDIConnectionToken: Route] = [:]
    /// The last input minted for a resolved connection; never reused, because a fresh stream starts every start.
    private var lastInput: UInt32 = 0
    /// The connected sources as last applied, in reported order. One whose registration was refused (registry full,
    /// or its key already live) is listed unresolved, because it feeds the legacy source.
    private(set) var sources: [MIDIConnectedSource] = []
    /// Batches dropped whole because their token has no live connection (for example one in flight at a detach).
    private(set) var droppedBatches = 0

    var snapshot: MIDISourceRegistrySnapshot { registry.snapshot }

    static func make(
        profile: MIDISourceProfile = LaunchControlXLMapping.sourceProfile
    ) throws(MIDISourceRefusal) -> LaunchControlXLStream {
        var registry = try MIDISourceRegistry.make(maximumSources: maximumSources, maximumFeedBytes: maximumPacketBytes)
        try registry.register(input, key: key, profile: profile)
        return LaunchControlXLStream(registry: registry, profile: profile)
    }

    private init(registry: MIDISourceRegistry, profile: MIDISourceProfile) {
        self.registry = registry
        self.profile = profile
    }

    /// Applies the whole list of connected sources. Every connection that is gone, or asks for a different key, is
    /// detached first, so its state never carries and a replug under the same key is not refused as ambiguous; then
    /// every new connection registers, or shares the legacy source when it is unresolved or refused. Returns true
    /// when the legacy source gained or lost a connection, the only live source whose membership can change.
    @discardableResult
    mutating func connect(_ connected: [MIDIConnectedSource]) -> Bool {
        var incoming: [MIDIConnectionToken: MIDIConnectedSource] = [:]
        for source in connected where incoming[source.token] == nil {
            incoming[source.token] = source
        }
        var sharedChanged = false
        for (token, route) in routes.sorted(by: { $0.key < $1.key })
        where incoming[token].map({ $0.endpoint != route.requested }) ?? true {
            routes[token] = nil
            if route.input == Self.input {
                sharedChanged = true
            } else {
                // Registered by `connect` and detached only here, so this cannot be refused.
                _ = try? registry.detach(route.input)
            }
        }
        var applied: [MIDIConnectedSource] = []
        for source in connected where !applied.contains(where: { $0.token == source.token }) {
            if let route = routes[source.token] {
                applied.append(route.input == Self.input ? Self.unresolved(source) : source)
            } else if let input = register(source) {
                routes[source.token] = Route(requested: source.endpoint, input: input)
                applied.append(source)
            } else {
                routes[source.token] = Route(requested: source.endpoint, input: Self.input)
                applied.append(Self.unresolved(source))
                sharedChanged = true
            }
        }
        sources = applied
        return sharedChanged
    }

    /// Feeds each packet in order, into the source `token` is routed to (the legacy source when nil), and
    /// concatenates the outputs. A token with no live connection drops the batch whole and counts it. A packet over
    /// `maximumPacketBytes` adds nothing and leaves the parser and state as they were.
    mutating func feed(packets: [[UInt8]], from token: MIDIConnectionToken? = nil) -> [MIDISourceOutput] {
        var input = Self.input
        if let token {
            guard let route = routes[token] else {
                droppedBatches += 1
                return []
            }
            input = route.input
        }
        var outputs: [MIDISourceOutput] = []
        for packet in packets {
            do throws(MIDISourceRefusal) {
                outputs += try registry.feed(packet, from: input)
            } catch {
                continue
            }
        }
        return outputs
    }

    /// Starts every source fresh through `MIDISourceRegistry.resetSource`: half messages, running status, open SysEx
    /// and state are dropped. The released notes are discarded; the surface maps only control changes.
    mutating func reset() {
        for source in registry.sources {
            _ = try? registry.resetSource(source.input)
        }
    }

    /// Starts only the legacy source fresh, as `reset()` does for every source.
    mutating func resetSharedSource() {
        // `input` is registered by `make` and never detached, so this cannot be refused.
        _ = try? registry.resetSource(Self.input)
    }

    /// Nil when the source is unresolved, or the registry refuses it (full, or its key already live).
    private mutating func register(_ source: MIDIConnectedSource) -> MIDIInputID? {
        guard let key = source.endpoint, lastInput < UInt32.max else { return nil }
        let input = MIDIInputID(lastInput + 1)
        do throws(MIDISourceRefusal) {
            try registry.register(input, key: key, profile: profile)
        } catch {
            return nil
        }
        lastInput += 1
        return input
    }

    private static func unresolved(_ source: MIDIConnectedSource) -> MIDIConnectedSource {
        MIDIConnectedSource(token: source.token, endpoint: nil, name: source.name)
    }
}
