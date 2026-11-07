/// One validated control source: the sending origin, channel (1...16), kind and number. Constructible only through the
/// throwing initializer, so no unvalidated key exists. `sourceID` is derived once as
/// `midi.<origin>.<channel>.<kind>.<number>` in decimal (for example `midi.lcxl-1.16.cc14.5`); the origin charset
/// has no `.`, so equal IDs mean equal keys. Deliberately not `Codable`: `ControlSourceID` is the persisted form.
/// Ordering compares (origin bytes, channel, kind order, number).
struct ControlSourceKey: Hashable, Comparable, Sendable {
    let origin: ControlSourceOrigin
    let channel: UInt8
    let kind: ControlSourceKind
    let number: UInt16
    let sourceID: ControlSourceID

    /// Checks the channel first (`.invalidChannel`), then the number against `kind.numberRange` (`.invalidNumber`).
    init(
        origin: ControlSourceOrigin, channel: UInt8, kind: ControlSourceKind, number: UInt16
    ) throws(ControlIntakeRefusal) {
        guard ControlIntakeBounds.channelRange.contains(channel) else { throw .invalidChannel(Int(channel)) }
        guard kind.numberRange.contains(number) else { throw .invalidNumber(Int(number)) }
        let raw = "\(ControlIntakeBounds.sourceIDPrefix)\(origin.token).\(channel).\(kind.rawValue).\(number)"
        // Unreachable: the origin charset and length bound the ID to at most 51 bytes of `[a-z0-9.-]`, which is
        // always a valid `ControlSourceID`.
        guard let sourceID = ControlSourceID(rawValue: raw) else { throw .invalidOrigin(length: 0) }
        self.origin = origin
        self.channel = channel
        self.kind = kind
        self.number = number
        self.sourceID = sourceID
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.origin, lhs.channel, lhs.kind, lhs.number) < (rhs.origin, rhs.channel, rhs.kind, rhs.number)
    }
}
