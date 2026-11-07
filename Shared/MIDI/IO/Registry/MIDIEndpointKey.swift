/// The identity of one physical MIDI endpoint, as far as an adapter can tell. Opaque: the registry never parses,
/// derives or normalises it, and equal keys mean "the same unit". Two live sources with an equal key are ambiguous
/// (for example two identical devices that report the same identity) and the registry refuses the second one until
/// the caller resolves it by choosing a different `ordinal`. Nothing here guesses, auto-increments or prefers the
/// newer unit.
struct MIDIEndpointKey: Hashable, Comparable, Sendable {
    /// Adapter-supplied hash of whatever identity evidence it has (never a name or address interpreted here).
    let fingerprint: UInt64
    /// A person-chosen number that tells apart units with the same fingerprint; 0 unless chosen otherwise.
    let ordinal: UInt8

    init(fingerprint: UInt64, ordinal: UInt8 = 0) {
        self.fingerprint = fingerprint
        self.ordinal = ordinal
    }

    /// Fingerprint first, then ordinal: a total order for callers that sort or index keys. The registry itself
    /// lists sources by `MIDIInputID` and only compares keys for equality.
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.fingerprint, lhs.ordinal) < (rhs.fingerprint, rhs.ordinal)
    }
}
