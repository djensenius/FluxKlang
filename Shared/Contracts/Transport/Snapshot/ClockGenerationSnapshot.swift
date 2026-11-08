//
//  ClockGenerationSnapshot.swift
//  FluxKlang
//
//  One contract type for the three clock generations a stamp must match before
//  it is used (#108 GU1, slice a). `MetronomeGenerations`, `MIDIClipGenerations`
//  and `AutomationRenderGenerations` hold the same three numbers and name this
//  type as their follow-up. Generations compare by equality only (media
//  contract rule M2): a stamp is current when its generation equals the live
//  one, never because it is "newer".
//

/// The sample clock, transport and musical map generations of one clock set, read from a ledger or carried by a
/// stamp. The fields are validated `Generation` values, so a snapshot cannot be built from raw integers.
struct ClockGenerationSnapshot: Hashable, Sendable {
    let sample: Generation
    let transport: Generation
    let musicalMap: Generation
}

/// Why a ledger gives no snapshot. The checks run in the order of the cases.
enum ClockGenerationRefusal: Error, Equatable, Sendable {
    /// The ledger has no musical clock, so it has no transport or musical map counter.
    case noMusicalClock
    /// A counter the clocks imply is missing: the first missing one of sample, transport, musical map.
    case undeclared(GenerationKey)
}

extension ClockGenerationSnapshot {
    /// The live generations of `ledger`: its primary sample clock, and the transport and musical map of its musical
    /// clock. The ledger is read by value and never changed.
    static func live(from ledger: GenerationLedger) throws(ClockGenerationRefusal) -> ClockGenerationSnapshot {
        try live(primaryClock: ledger.primaryClock, musicalClock: ledger.musicalClock, counters: ledger.current)
    }

    /// The check behind `live(from:)`, on the three facts a ledger holds. `GenerationLedger` declares every counter
    /// its clocks imply, has one initializer and no way to remove a counter, and the ledger tests read a fresh, a
    /// declared-into and a bumped one without `.undeclared`; this entry lets the order of the refusals be exercised
    /// on counter sets that no such ledger holds.
    static func live(primaryClock: GenerationKey, musicalClock: ClockID?,
                     counters: [GenerationKey: Generation]) throws(ClockGenerationRefusal) -> ClockGenerationSnapshot {
        guard let musicalClock else { throw .noMusicalClock }
        let transportKey = GenerationKey(.transport, musicalClock)
        let musicalMapKey = GenerationKey(.musicalMap, musicalClock)
        guard let sample = counters[primaryClock] else { throw .undeclared(primaryClock) }
        guard let transport = counters[transportKey] else { throw .undeclared(transportKey) }
        guard let musicalMap = counters[musicalMapKey] else { throw .undeclared(musicalMapKey) }
        return ClockGenerationSnapshot(sample: sample, transport: transport, musicalMap: musicalMap)
    }
}
