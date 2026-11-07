//
//  PeerStatusEntry.swift
//  FluxKlang
//
//  One parameter a controller may see (#95, slice C1): the display fields of a
//  `.live` descriptor plus whether this peer may write it. It never carries the
//  default value, the safety ceiling, the graph node, unknown fields or any
//  grant or trust data. The only constructors are the throwing `make` (for
//  values decoded from a peer) and `project` (from a validated descriptor).
//

struct PeerStatusEntry: Hashable, Sendable {
    let id: ParameterID
    let unit: ParameterUnit
    let lower: Double
    let upper: Double
    let controlClass: ControlClass
    let verification: MeasurementStatus
    let writable: Bool

    /// The display fields of an entry before validation; the input of `make`.
    struct Fields: Hashable, Sendable {
        var id: ParameterID
        var unit: ParameterUnit
        var lower: Double
        var upper: Double
        var controlClass: ControlClass
        var verification: MeasurementStatus
        var writable: Bool
    }

    private init(_ fields: Fields) {
        id = fields.id
        unit = fields.unit
        lower = fields.lower
        upper = fields.upper
        controlClass = fields.controlClass
        verification = fields.verification
        writable = fields.writable
    }

    /// Validates the fields in the order of `PeerStatusEntryFault`.
    static func make(_ fields: Fields) throws(PeerStatusError) -> PeerStatusEntry {
        let id = fields.id
        guard fields.lower.isFinite, fields.upper.isFinite else { throw .invalidEntry(id, .nonFiniteBound) }
        guard fields.lower <= fields.upper else { throw .invalidEntry(id, .invertedBounds) }
        guard fields.controlClass == .live else { throw .invalidEntry(id, .notLive(fields.controlClass)) }
        guard fitsUnit(fields.unit, lower: fields.lower, upper: fields.upper) else {
            throw .invalidEntry(id, .unitBounds(fields.unit))
        }
        return PeerStatusEntry(fields)
    }

    /// The entry `grants` may see for `descriptor`, or nil. A grant set with `.statusRead` sees every `.live`
    /// descriptor; any other sees only the descriptors it holds a `.live` parameter grant for.
    /// Structural and hazardous descriptors are never projected.
    static func project(_ descriptor: ParameterDescriptor, grants: PeerGrantSet) -> PeerStatusEntry? {
        let fields = descriptor.fields
        guard fields.controlClass == .live else { return nil }
        let granted = grants.permits(.live, .parameter(fields.id))
        guard granted || grants.reads.contains(.statusRead) else { return nil }
        return PeerStatusEntry(Fields(id: fields.id, unit: fields.unit, lower: fields.lower, upper: fields.upper,
                                      controlClass: fields.controlClass, verification: fields.verification,
                                      writable: granted))
    }

    /// Ascending by the UTF-8 bytes of the id; never Character order.
    static func precedes(_ lhs: ParameterID, _ rhs: ParameterID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    /// Negative zero equals zero, so a change between them is not a change.
    private static func fitsUnit(_ unit: ParameterUnit, lower: Double, upper: Double) -> Bool {
        switch unit {
        case .boolean: lower == 0 && upper == 1
        case .normalized: lower >= 0 && upper <= 1
        case .percent: lower >= 0 && upper <= 100
        case .index: lower.rounded() == lower && upper.rounded() == upper
        case .decibels, .pan: true
        }
    }
}

extension Sequence where Element == PeerStatusEntry {
    /// Entries ascending by id bytes.
    func sortedByID() -> [PeerStatusEntry] {
        sorted { PeerStatusEntry.precedes($0.id, $1.id) }
    }

    /// The smallest id that appears more than once, if any.
    func smallestDuplicateID() -> ParameterID? {
        let ordered = sortedByID()
        for index in ordered.indices.dropFirst() where ordered[index].id == ordered[index - 1].id {
            return ordered[index].id
        }
        return nil
    }
}
