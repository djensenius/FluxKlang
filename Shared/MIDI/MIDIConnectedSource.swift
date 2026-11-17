//
//  MIDIConnectedSource.swift
//  FluxKlang
//

/// Names one CoreMIDI connection for one input start (#81). Minted on the main actor from a counter that starts at 1,
/// is never 0 and never repeats within a start, and handed to `MIDIPortConnectSource` as the connection's refCon, so
/// the read callback learns which connection a packet list came from without allocating or locking.
struct MIDIConnectionToken: Hashable, Comparable, Sendable {
    let rawValue: UInt

    /// Nil for 0, which is never a token.
    init?(rawValue: UInt) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }

    /// The token a connection was made with; nil for a null refCon.
    init?(refCon: UnsafeMutableRawPointer?) {
        self.init(rawValue: UInt(bitPattern: refCon))
    }

    /// The refCon to connect with. Never nil, because the raw value is never 0; nothing is allocated or dereferenced.
    var refCon: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One connected source as an input reports it (#81).
struct MIDIConnectedSource: Equatable, Sendable {
    let token: MIDIConnectionToken
    /// The unit's own endpoint key, or nil when it is unresolved: its identity is unavailable, ambiguous with another
    /// connected unit, or a fingerprint of 0. An unresolved unit feeds the stream's one shared legacy source, as every
    /// unit did before #81, until a person resolves it by choosing an ordinal (a later slice). No ordinal is ever
    /// chosen automatically.
    let endpoint: MIDIEndpointKey?
    /// The display name, for status only; never identity.
    let name: String

    var isResolved: Bool { endpoint != nil }
}
