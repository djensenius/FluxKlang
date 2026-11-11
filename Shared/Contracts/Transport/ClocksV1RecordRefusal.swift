//
//  ClocksV1RecordRefusal.swift
//  FluxKlang
//
//  Why a transport document cannot become the contract v1 trace header's `clocks` object (#84 CXR1). In memory
//  only; nothing is clamped, remapped or serialized in its place.
//

/// The first offence `ClocksV1Record.make` finds, in this order: the musical clock's presence, the host timebase,
/// then the clock IDs (sample clocks in order, primary first, then the musical clock), the extra sample clocks'
/// rates, a repeated clock ID, then extension fields on the tempo map, meter or loop.
enum ClocksV1RecordRefusal: Error, Hashable, Sendable {
    /// The transport document declares no musical clock; the schema requires `clocks.musical`.
    case missingMusicalClock
    /// `timebaseNumer` or `timebaseDenom` is 0; the schema's `$defs.positive` needs both at least 1.
    case invalidTimebase(numer: UInt32, denom: UInt32)
    /// A clock ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidClockID(ClockID)
    /// An extra sample clock names a rate outside the v1 `$defs.rate` set (`MediaNominalRate`).
    case invalidRate(clock: ClockID, rate: Int)
    /// A clock ID is declared twice: among the sample clocks (the checker's duplicate `clockId` error), or as both
    /// a sample clock and the musical clock (media-contract.md §3: clock IDs are unique).
    case duplicateClockID(ClockID)
    /// A tempo segment, the meter or the loop carries additive extension fields, which `clocks` cannot hold
    /// (`additionalProperties: false`).
    case extensionFields
}
