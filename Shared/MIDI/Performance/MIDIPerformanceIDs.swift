/// Opaque identity of one MIDI destination route. Graph compilation (#66) and endpoints (#81) map their own
/// identities onto these. `RouteID` is not reused: it names a host audio route bound to device channels, and the
/// String-backed `ContractID` would add hashing and comparison cost to every routed event.
struct MIDIRouteID: Hashable, Comparable, Sendable {
    let rawValue: UInt32

    init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Opaque identity of one MIDI input (a source) whose events the ledger routes.
struct MIDIInputID: Hashable, Comparable, Sendable {
    let rawValue: UInt32

    init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
