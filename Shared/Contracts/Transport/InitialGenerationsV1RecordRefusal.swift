//
//  InitialGenerationsV1RecordRefusal.swift
//  FluxKlang
//
//  Why a set of counters cannot become the contract v1 trace's `initialGenerations` map (#84 IGX1,
//  media-contract §5.1). In memory only; nothing is dropped, clamped, remapped or serialized in its place.
//

/// The first offence `InitialGenerationsV1Record.make` finds, in this order: an empty map, then each counter in
/// ascending UTF-8 byte order of its `kind/subject` string, checked for its subject and then, for `transport` and
/// `musicalMap` counters, its musical clock.
enum InitialGenerationsV1RecordRefusal: Error, Hashable, Sendable {
    /// No counters; `$defs.generationMap` has `minProperties: 1`.
    case empty
    /// The counter subject does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`, so the
    /// `kind/subject` string fails `$defs.counter`.
    case invalidCounterSubject(GenerationKey)
    /// A `transport` or `musicalMap` counter whose subject is not the declared musical clock, or any such counter
    /// when no musical clock is declared. The checker rejects it even if it is never bumped.
    case undeclaredMusicalClock(GenerationKey)
}
