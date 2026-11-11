//
//  InitialGenerationsV1Record.swift
//  FluxKlang
//
//  The counters a trace starts from, as the media contract v1 trace's top-level `initialGenerations` map
//  (#84 IGX1, media-contract §5.1): validated fail-closed and encoded deterministically. Pure: it reads a
//  snapshot and writes no file; it neither declares nor bumps a counter.
//

import Foundation

/// The `initialGenerations` field (`$defs.generationMap`) of a contract v1 trace. Built only by `make`.
///
/// Snapshot the counters before the trace's first `generationRecord`: the checker replays every bump from this map,
/// so a map taken after a bump makes that bump's `from` stale. Values other than 1 are allowed (a trace may start
/// from counters that already moved); `make` does not check that they are `Generation.initial`.
///
/// The source types already guarantee the schema's other bounds, so they have no refusal here: every value is in
/// 1…2^53 − 1 (`Generation`), inside `$defs.generation`'s 1…2^64 − 1, every kind is one of the six `$defs.counter`
/// kinds (`GenerationKind`), and keys are unique because `kind/subject` is injective (a kind has no `/`).
///
/// Not checked here, because they need the `clocks` header: that a `sampleClock` counter names a declared sample
/// clock. The checker does not require one, but an anchor on a sample clock with no initial generation fails.
struct InitialGenerationsV1Record: Hashable, Sendable {
    let generations: [GenerationKey: Generation]

    /// Builds the map from `generations`, or throws the first refusal in the order
    /// `InitialGenerationsV1RecordRefusal` documents. Never drops, clamps or remaps a counter.
    ///
    /// `musicalClock` is the trace's `clocks.musical.clockId`; every `transport` and `musicalMap` counter must name
    /// it. v1 traces always declare a musical clock, so nil only fits a `GenerationLedger` without transport (no
    /// musical counters); such a trace is refused later, at the `clocks` header.
    static func make(generations: [GenerationKey: Generation],
                     musicalClock: ClockID?) throws(InitialGenerationsV1RecordRefusal) -> InitialGenerationsV1Record {
        guard !generations.isEmpty else { throw .empty }
        let musicalSubject = musicalClock.map(\.rawValue)
        let ordered = generations.keys.sorted { $0.description.utf8.lexicographicallyPrecedes($1.description.utf8) }
        for key in ordered {
            guard MediaContractV1ID.matches(key.subject.rawValue) else { throw .invalidCounterSubject(key) }
            if key.kind == .transport || key.kind == .musicalMap, key.subject.rawValue != musicalSubject {
                throw .undeclaredMusicalClock(key)
            }
        }
        return InitialGenerationsV1Record(generations: generations)
    }

    /// Builds the map from the ledger's current counters and musical clock. Call it before the first bump; see the
    /// type's documentation.
    static func make(from ledger: GenerationLedger) throws(InitialGenerationsV1RecordRefusal)
        -> InitialGenerationsV1Record {
        try make(generations: ledger.current, musicalClock: ledger.musicalClock)
    }

    private init(generations: [GenerationKey: Generation]) {
        self.generations = generations
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`): one `"kind/subject": value`
    /// member per counter. Identical input encodes to identical bytes. The output is bounded by the input: each
    /// member is a subject of at most `ContractID.maximumLength` (128) bytes and a value of at most 16 digits.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension InitialGenerationsV1Record: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let members = Dictionary(uniqueKeysWithValues: generations.map { ($0.key.description, $0.value) })
        try container.encode(members)
    }
}
