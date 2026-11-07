//
//  RigReservationLimits.swift
//  FluxKlang
//
//  Every numeric bound of the rig reservation ledger, in one place.
//

/// The numeric bounds of the rig reservation ledger (#68). No other file repeats one of these numbers.
enum RigReservationLimits {
    /// Longest accepted `RigToken`, in UTF-8 bytes.
    static let maximumTokenBytes = 64
    /// Largest accepted `RigInstant`, in seconds (2^53 - 1, exactly representable everywhere).
    static let maximumInstantSeconds = 9_007_199_254_740_991
    /// Longest accepted reservation window (7 days), in seconds.
    static let maximumWindowSeconds = 604_800
    /// Reservations a ledger holds; released reservations stay in the ledger and count.
    static let maximumReservations = 64
    /// Experiments one reservation may record.
    static let maximumExperimentsPerReservation = 16
    /// Lowest accepted baseline sample rate.
    static let minimumSampleRateHertz = 8_000
    /// Highest accepted baseline sample rate.
    static let maximumSampleRateHertz = 768_000
    /// Smallest accepted baseline buffer size.
    static let minimumBufferFrames = 1
    /// Largest accepted baseline buffer size.
    static let maximumBufferFrames = 16_384
}
