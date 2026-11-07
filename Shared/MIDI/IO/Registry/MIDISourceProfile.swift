/// What a source does with System Reset (FF). The default is `.ignore`: one stray FF must not erase a performer's
/// state, and no timeout is involved either way.
enum MIDISystemResetPolicy: Equatable, Hashable, Sendable {
    /// FF is passed through as a real-time event; parser and state are untouched.
    case ignore
    /// FF reports every held note, then replaces the source's state and parser with fresh ones. An explicit,
    /// per-source opt-in; no other source is affected.
    case resetSource
}

/// The validated receiver profile of one source: its MIDI 1 state policy, its SysEx payload bound and its System
/// Reset policy. Only `make` builds one (apart from `standard`), so the SysEx bound is always in range.
struct MIDISourceProfile: Equatable, Hashable, Sendable {
    static let sysExPayloadBounds = 1...65_536
    static let defaultSysExPayloadBytes = 4_096
    static let standard = MIDISourceProfile(
        statePolicy: .standard, maximumSysExPayloadBytes: defaultSysExPayloadBytes, systemReset: .ignore
    )

    let statePolicy: MIDI1StatePolicy
    /// Passed to the source's parser; a longer payload is discarded by the parser's own contract.
    let maximumSysExPayloadBytes: Int
    let systemReset: MIDISystemResetPolicy

    /// Refuses a SysEx bound outside `sysExPayloadBounds` with `.invalidConfiguration(.maximumSysExPayloadBytes)`.
    static func make(
        statePolicy: MIDI1StatePolicy = .standard,
        maximumSysExPayloadBytes: Int = defaultSysExPayloadBytes,
        systemReset: MIDISystemResetPolicy = .ignore
    ) throws(MIDISourceRefusal) -> MIDISourceProfile {
        guard sysExPayloadBounds.contains(maximumSysExPayloadBytes) else {
            throw .invalidConfiguration(.maximumSysExPayloadBytes)
        }
        return MIDISourceProfile(
            statePolicy: statePolicy, maximumSysExPayloadBytes: maximumSysExPayloadBytes, systemReset: systemReset
        )
    }

    private init(statePolicy: MIDI1StatePolicy, maximumSysExPayloadBytes: Int, systemReset: MIDISystemResetPolicy) {
        self.statePolicy = statePolicy
        self.maximumSysExPayloadBytes = maximumSysExPayloadBytes
        self.systemReset = systemReset
    }
}
