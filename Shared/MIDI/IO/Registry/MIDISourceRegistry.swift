/// A live source as listed by the registry.
struct MIDISourceDescriptor: Equatable, Sendable {
    let input: MIDIInputID
    let key: MIDIEndpointKey
    let profile: MIDISourceProfile
}

/// A value copy of one source: its descriptor and the snapshot of its MIDI 1 state. Parser framing is private.
struct MIDISourceSnapshot: Equatable, Sendable {
    let input: MIDIInputID
    let key: MIDIEndpointKey
    let profile: MIDISourceProfile
    let state: MIDI1PerformanceSnapshot
}

/// A value copy of the whole registry, sources ascending by `MIDIInputID`.
struct MIDISourceRegistrySnapshot: Equatable, Sendable {
    let maximumSources: Int
    let maximumFeedBytes: Int
    let sources: [MIDISourceSnapshot]
}

/// A bounded, pure registry of MIDI 1 sources: one parser, one `MIDI1PerformanceState` and one profile per
/// `MIDIInputID`, so the bytes of one source can never frame, or change the state of, another. The caller injects
/// every `MIDIInputID` (nothing is minted) and the opaque `MIDIEndpointKey` that says which unit it is. Only `make`
/// builds a registry, so both limits are always in range.
///
/// No clock, timeout, thread, queue or CoreMIDI: every call is a synchronous mutation of this value. Sources are
/// kept ascending by `MIDIInputID`; no dictionary order reaches any result. Every refused call leaves every source
/// unchanged, and `feed` decides its call-level refusals before it consumes a byte.
struct MIDISourceRegistry: Sendable {
    static let sourceBounds = 1...128
    static let feedByteBounds = 1...65_536
    static let defaultMaximumSources = 32
    static let defaultMaximumFeedBytes = 4_096

    let maximumSources: Int
    let maximumFeedBytes: Int
    private var bindings: [Source] = []

    var count: Int { bindings.count }

    /// Ascending by `MIDIInputID`.
    var sources: [MIDISourceDescriptor] { bindings.map(\.descriptor) }

    var snapshot: MIDISourceRegistrySnapshot {
        MIDISourceRegistrySnapshot(
            maximumSources: maximumSources, maximumFeedBytes: maximumFeedBytes, sources: bindings.map(\.snapshot)
        )
    }

    /// Refuses limits outside `sourceBounds` and `feedByteBounds` with `.invalidConfiguration`; sources are checked
    /// first.
    static func make(
        maximumSources: Int = defaultMaximumSources, maximumFeedBytes: Int = defaultMaximumFeedBytes
    ) throws(MIDISourceRefusal) -> MIDISourceRegistry {
        guard sourceBounds.contains(maximumSources) else { throw .invalidConfiguration(.maximumSources) }
        guard feedByteBounds.contains(maximumFeedBytes) else { throw .invalidConfiguration(.maximumFeedBytes) }
        return MIDISourceRegistry(maximumSources: maximumSources, maximumFeedBytes: maximumFeedBytes)
    }

    private init(maximumSources: Int, maximumFeedBytes: Int) {
        self.maximumSources = maximumSources
        self.maximumFeedBytes = maximumFeedBytes
    }

    /// Adds a source with fresh parser and state. Refusals, in this order: `.duplicateInput`, `.ambiguousEndpoint`
    /// (a live source has an equal key; the existing binding is untouched and the caller resolves it with another
    /// ordinal), `.registryFull`.
    mutating func register(
        _ input: MIDIInputID, key: MIDIEndpointKey, profile: MIDISourceProfile = .standard
    ) throws(MIDISourceRefusal) {
        let position = insertionIndex(of: input)
        if position < bindings.count, bindings[position].input == input { throw .duplicateInput(input) }
        if let existing = bindings.first(where: { $0.key == key }) {
            throw .ambiguousEndpoint(existing: existing.input)
        }
        guard bindings.count < maximumSources else { throw .registryFull(limit: maximumSources) }
        guard let source = Source(input: input, key: key, profile: profile) else {
            throw .invalidConfiguration(.maximumSysExPayloadBytes)
        }
        bindings.insert(source, at: position)
    }

    /// Removes the source, frees its endpoint key and reports every note it held (even under `.ignore`), ascending.
    mutating func detach(_ input: MIDIInputID) throws(MIDISourceRefusal) -> [MIDISourceRelease] {
        guard let index = index(of: input) else { throw .unknownInput(input) }
        return bindings.remove(at: index).releases
    }

    /// A caller-driven reset, whatever the profile says: reports every held note and starts the source fresh.
    mutating func resetSource(_ input: MIDIInputID) throws(MIDISourceRefusal) -> [MIDISourceRelease] {
        guard let index = index(of: input) else { throw .unknownInput(input) }
        return bindings[index].reset()
    }

    /// Runs the bytes through that source's parser and state in order and returns one output per emitted event.
    /// Per-event state refusals are `.refused` outputs and do not stop the feed. `.unknownInput` and
    /// `.feedTooLarge` (checked in that order) are decided before any byte is consumed.
    mutating func feed(_ bytes: [UInt8], from input: MIDIInputID) throws(MIDISourceRefusal) -> [MIDISourceOutput] {
        guard let index = index(of: input) else { throw .unknownInput(input) }
        guard bytes.count <= maximumFeedBytes else {
            throw .feedTooLarge(count: bytes.count, limit: maximumFeedBytes)
        }
        return bindings[index].consume(bytes)
    }

    /// Binary search over the ascending bindings: the first position whose input is not below `input`.
    private func insertionIndex(of input: MIDIInputID) -> Int {
        var low = 0
        var high = bindings.count
        while low < high {
            let middle = low + (high - low) / 2
            if bindings[middle].input < input { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func index(of input: MIDIInputID) -> Int? {
        let position = insertionIndex(of: input)
        guard position < bindings.count, bindings[position].input == input else { return nil }
        return position
    }
}
