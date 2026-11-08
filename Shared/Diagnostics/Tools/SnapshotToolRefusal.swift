//
//  SnapshotToolRefusal.swift
//  FluxKlang
//
//  Why a read-only snapshot tool refused to answer. A refusal carries no partial
//  result, and nothing a tool does can change the snapshot it reads.
//

/// The typed refusals of `SnapshotToolCatalog.run`, in the order they are decided:
/// `invalidToolLimits`, `invalidIdentifier` (first argument first), `limitOutOfRange`, `pageOutOfRange`,
/// `notFound`, `resultTooLarge`.
enum SnapshotToolRefusal: Error, Equatable, Sendable {
    /// The identifier argument that failed.
    enum Field: Equatable, Sendable, CaseIterable {
        case nodeID
        case portID
        case parameterID
    }

    /// The tool limits are outside their bounds (possible only for a value that was not built by `make`).
    case invalidToolLimits(maximumBytes: Int, maximumPageLimit: Int)
    /// The argument is empty, longer than 128 UTF-8 bytes or not a valid contract identifier.
    case invalidIdentifier(Field)
    /// The page `limit` is outside `1...maximumPageLimit`; carries the value given.
    case limitOutOfRange(Int)
    /// The page `offset` is negative or above the snapshot's cap for that category; carries the value given.
    case pageOutOfRange(Int)
    /// The identifier is well formed but names nothing in the snapshot (never matched by prefix).
    case notFound
    /// The first item of the page alone has more UTF-8 bytes than the cap; carries that item's bytes.
    case resultTooLarge(Int)
}
