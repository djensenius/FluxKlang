//
//  Revisions.swift
//  FluxKlang
//
//  Counters shared by the contracts: a `ContractRevision` orders successive
//  states of one document, and a `Generation` names an epoch of meaning. Both
//  encode as bare JSON integers.
//

import Foundation

/// Why a revision or generation value is not valid.
enum RevisionError: Error, Equatable, Sendable {
    /// A revision must be zero or greater.
    case negativeRevision(Int)
    /// A generation must be 1 or greater.
    case invalidGeneration(Int)
    /// `found` at `index` does not strictly follow `previous`.
    case notStrictlyIncreasing(index: Int, previous: ContractRevision, found: ContractRevision)
}

/// A non-negative revision number. Successive revisions of a document must be
/// strictly increasing.
struct ContractRevision: Hashable, Comparable, Sendable, CustomStringConvertible {
    static let initial = ContractRevision(uncheckedValue: 0)

    let value: Int

    init(_ value: Int) throws(RevisionError) {
        guard value >= 0 else { throw .negativeRevision(value) }
        self.value = value
    }

    private init(uncheckedValue: Int) {
        value = uncheckedValue
    }

    var description: String { String(value) }

    /// The following revision. Traps on `Int.max`, which no real document reaches.
    func next() -> ContractRevision {
        ContractRevision(uncheckedValue: value + 1)
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

/// An epoch counter that starts at 1 and steps by exactly 1. Generations are
/// compared for equality only (media contract rule M2): a stamp is current when
/// its generation equals the live one, never because it is "newer". It is
/// therefore deliberately not `Comparable`.
struct Generation: Hashable, Sendable, CustomStringConvertible {
    static let initial = Generation(uncheckedValue: 1)

    let value: Int

    init(_ value: Int) throws(RevisionError) {
        guard value >= 1 else { throw .invalidGeneration(value) }
        self.value = value
    }

    private init(uncheckedValue: Int) {
        value = uncheckedValue
    }

    var description: String { String(value) }

    /// The following generation. Traps on `Int.max`, which no real epoch reaches.
    func next() -> Generation {
        Generation(uncheckedValue: value + 1)
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
