//
//  Revisions.swift
//  FluxKlang
//
//  Counters shared by the contracts: a `ContractRevision` orders successive
//  states of one document, and a `Generation` names an epoch of meaning. Both
//  encode as bare JSON integers and stay within 0…2^53−1, the integers every
//  JSON reader represents exactly. They are always non-negative, so the
//  G-MEDIA contract's `UInt64` fields bridge losslessly with `UInt64(value)`.
//  As with any `Int` decode, an integral literal such as `2.0` is accepted.
//

import Foundation

/// Why a revision or generation value is not valid.
enum RevisionError: Error, Equatable, Sendable {
    /// The value is outside 0…`maximumValue` (revisions) or 1…`maximumValue`
    /// (generations).
    case outOfRange(Int)
    /// `next()` was called on `maximumValue`.
    case overflow
    /// `found` at `index` does not strictly follow `previous`.
    case notStrictlyIncreasing(index: Int, previous: ContractRevision, found: ContractRevision)
}

/// A revision number in 0…`maximumValue`. Successive revisions of a document
/// must be strictly increasing.
struct ContractRevision: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// 2^53 − 1, the largest JSON-safe integer.
    static let maximumValue = 9_007_199_254_740_991
    static let initial = ContractRevision(uncheckedValue: 0)

    let value: Int

    init(_ value: Int) throws(RevisionError) {
        guard (0...Self.maximumValue).contains(value) else { throw .outOfRange(value) }
        self.value = value
    }

    private init(uncheckedValue: Int) {
        value = uncheckedValue
    }

    var description: String { String(value) }

    /// The following revision; throws `.overflow` at `maximumValue`.
    func next() throws(RevisionError) -> ContractRevision {
        guard value < Self.maximumValue else { throw .overflow }
        return ContractRevision(uncheckedValue: value + 1)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    /// Throws unless every revision is strictly greater than the one before it.
    static func validateStrictlyIncreasing(
        _ revisions: some Sequence<ContractRevision>
    ) throws(RevisionError) {
        var previous: ContractRevision?
        for (index, revision) in revisions.enumerated() {
            if let previous, revision <= previous {
                throw .notStrictlyIncreasing(index: index, previous: previous, found: revision)
            }
            previous = revision
        }
    }
}

extension ContractRevision: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid revision \(raw): \(error)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// An epoch counter in 1…`maximumValue` that starts at 1 and steps by exactly 1.
/// Generations are compared for equality only (media contract rule M2): a stamp
/// is current when its generation equals the live one, never because it is
/// "newer". It is therefore deliberately not `Comparable`, and comparing
/// `.value` with `<` or `>` to get around that circumvents M2 and is not allowed.
struct Generation: Hashable, Sendable, CustomStringConvertible {
    /// 2^53 − 1, the largest JSON-safe integer.
    static let maximumValue = 9_007_199_254_740_991
    static let initial = Generation(uncheckedValue: 1)

    let value: Int

    init(_ value: Int) throws(RevisionError) {
        guard (1...Self.maximumValue).contains(value) else { throw .outOfRange(value) }
        self.value = value
    }

    private init(uncheckedValue: Int) {
        value = uncheckedValue
    }

    var description: String { String(value) }

    /// The following generation; throws `.overflow` at `maximumValue`.
    func next() throws(RevisionError) -> Generation {
        guard value < Self.maximumValue else { throw .overflow }
        return Generation(uncheckedValue: value + 1)
    }
}

extension Generation: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid generation \(raw): \(error)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
