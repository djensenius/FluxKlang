/// The configuration value a factory refused.
enum MIDISourceConfigurationField: Equatable, Hashable, Sendable {
    /// Registry source limit, 1...128.
    case maximumSources
    /// Registry per-feed byte limit, 1...65_536.
    case maximumFeedBytes
    /// Profile SysEx payload bound, 1...65_536.
    case maximumSysExPayloadBytes
}

/// Why a registry or profile operation was refused. Every refusal leaves every source, parser and state unchanged.
/// Per-event refusals of the MIDI 1 state are not thrown: they are `MIDISourceOutcome.refused` outputs.
enum MIDISourceRefusal: Error, Equatable, Hashable, Sendable {
    case invalidConfiguration(MIDISourceConfigurationField)
    /// The input id is already registered (checked first).
    case duplicateInput(MIDIInputID)
    /// A live source already has this endpoint key; resolve by choosing a different ordinal. The existing binding
    /// is never reassigned or marked stale.
    case ambiguousEndpoint(existing: MIDIInputID)
    /// `limit` sources are registered already.
    case registryFull(limit: Int)
    case unknownInput(MIDIInputID)
    /// The feed has more bytes than `limit`; no byte of it was consumed.
    case feedTooLarge(count: Int, limit: Int)
}
