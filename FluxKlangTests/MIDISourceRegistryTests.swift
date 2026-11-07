import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared fixtures of the per-source MIDI 1 registry tests. The test files of this suite are the extensions
/// `+Isolation`, `+Endpoint`, `+Reset` and `+Bounds`.
@Suite("MIDISourceRegistry")
struct MIDISourceRegistryTests {
    /// Bytes that expose hidden parser state: a pending data byte or running status completes into an event, and an
    /// open SysEx turns the F7 into a SysEx event instead of a bare System Common F7.
    static let probe: [UInt8] = [0x05, 0x06, 0x07, 0xF7, 0x05, 0x06]

    static func id(_ raw: UInt32) -> MIDIInputID { MIDIInputID(raw) }

    static func key(_ fingerprint: UInt64, _ ordinal: UInt8 = 0) -> MIDIEndpointKey {
        MIDIEndpointKey(fingerprint: fingerprint, ordinal: ordinal)
    }

    static func policy(
        heldNotes: Int = 128, parameters: Int = 256, retainLSB: Bool = false
    ) throws -> MIDI1StatePolicy {
        try #require(MIDI1StatePolicy(
            lsbReset: retainLSB ? .retainLSB : .resetOnMSB,
            maximumHeldNotes: heldNotes,
            maximumParameterValues: parameters
        ))
    }

    static func profile(
        reset: MIDISystemResetPolicy = .ignore, sysEx: Int = 4_096, policy: MIDI1StatePolicy = .standard
    ) throws -> MIDISourceProfile {
        try MIDISourceProfile.make(statePolicy: policy, maximumSysExPayloadBytes: sysEx, systemReset: reset)
    }

    /// Registers every raw id in the given order; the endpoint fingerprint is the raw id, the ordinal 0.
    static func registry(
        _ raws: [UInt32] = [1, 2], profile: MIDISourceProfile = .standard,
        maximumSources: Int = 32, maximumFeedBytes: Int = 4_096
    ) throws -> MIDISourceRegistry {
        var registry = try MIDISourceRegistry.make(maximumSources: maximumSources, maximumFeedBytes: maximumFeedBytes)
        for raw in raws { try registry.register(id(raw), key: key(UInt64(raw)), profile: profile) }
        return registry
    }

    /// The refusal `body` throws, or nil when it succeeds; any other error is recorded as a test issue.
    static func refusal<T>(_ body: () throws -> T) -> MIDISourceRefusal? {
        do {
            _ = try body()
            return nil
        } catch let refusal as MIDISourceRefusal {
            return refusal
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// Feeds the probe to a copy of every source and returns what each one emits.
    static func continuation(_ registry: MIDISourceRegistry) throws -> [[MIDISourceOutput]] {
        var copy = registry
        let size = registry.maximumFeedBytes
        return try registry.sources.map { source in
            try stride(from: 0, to: probe.count, by: size).flatMap {
                try copy.feed(Array(probe[$0..<min($0 + size, probe.count)]), from: source.input)
            }
        }
    }

    static func state(_ registry: MIDISourceRegistry, _ raw: UInt32) -> MIDI1PerformanceSnapshot? {
        registry.snapshot.sources.first { $0.input == id(raw) }?.state
    }

    static func held(_ registry: MIDISourceRegistry, _ raw: UInt32, channel: Int = 1) -> [MIDI1HeldNote] {
        state(registry, raw)?.channels[channel - 1].heldNotes ?? []
    }

    static func noteOn(_ channel: UInt8, _ note: UInt8, _ velocity: UInt8 = 100) -> [UInt8] {
        [0x90 | (channel - 1), note, velocity]
    }

    static func noteOff(_ channel: UInt8, _ note: UInt8) -> [UInt8] {
        [0x80 | (channel - 1), note, 0]
    }

    static func control(_ channel: UInt8, _ controller: UInt8, _ value: UInt8) -> [UInt8] {
        [0xB0 | (channel - 1), controller, value]
    }

    static func sustain(_ channel: UInt8, down: Bool) -> [UInt8] {
        control(channel, 64, down ? 127 : 0)
    }

    static func selectRPN(_ channel: UInt8, msb: UInt8, lsb: UInt8) -> [UInt8] {
        control(channel, 101, msb) + control(channel, 100, lsb)
    }

    /// Feeds each chunk to the source in turn and concatenates the outputs.
    static func feedChunks(
        _ registry: inout MIDISourceRegistry, _ chunks: [[UInt8]], from raw: UInt32
    ) throws -> [MIDISourceOutput] {
        var outputs: [MIDISourceOutput] = []
        for chunk in chunks { outputs += try registry.feed(chunk, from: id(raw)) }
        return outputs
    }

    static func events(_ outputs: [MIDISourceOutput]) -> [MIDI1Event] { outputs.map(\.event) }

    /// A deterministic mixed stream: statuses, data bytes, real-time, SysEx and System Common.
    static func stream(count: Int, seed: UInt64) -> [UInt8] {
        var generator = seed
        return (0..<count).map { _ in
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: generator >> 33)
        }
    }
}
