//
//  ResourceRefusal.swift
//  FluxKlang
//
//  The typed refusals of the plugin resource ledger and of the latency-change policy
//  (#78, slice PLG6). Every payload carries the numbers that caused the refusal so a
//  caller can show them; none of it is a message string. Pure values.
//

/// Why a reservation or a ledger was refused. A refused call returns no value and
/// leaves the ledger it was given unchanged.
enum ResourceRefusal: Error, Hashable, Sendable {
    /// `ResourceLedger.make`: the scratch total is below one byte.
    case totalTooSmall(requested: Int)
    /// `ResourceLedger.make`: the scratch total is above `ResourceLimits.maximumScratchBytes`.
    case totalTooLarge(requested: Int, maximum: Int)
    /// `ResourceLedger.make`: the instance capacity is below one.
    case instanceCapacityTooSmall(requested: Int)
    /// `ResourceLedger.make`: the instance capacity is above `ResourceLimits.maximumInstances`.
    case instanceCapacityTooLarge(requested: Int, maximum: Int)
    /// `ResourceReservation.make`: scratch bytes below zero or above the scratch limit.
    case scratchOutOfRange(requested: Int, maximum: Int)
    /// `ResourceReservation.make`: instances below zero or above the instance limit.
    case instancesOutOfRange(requested: Int, maximum: Int)
    /// `ResourceReservation.make`: no scratch, no instances and not pinned claims nothing.
    case emptyReservation
    /// `reserve`: the owner already holds a reservation in this ledger.
    case duplicateOwner(PluginIdentity)
    /// `reserve`: `count` is the number of reservations the ledger would hold.
    case tooManyReservations(count: Int, maximum: Int)
    /// `reserve`: `available` is the scratch still unreserved in this ledger.
    case insufficientScratch(needed: Int, available: Int)
    /// `reserve`: `available` is the instance capacity still unreserved in this ledger.
    case insufficientInstances(needed: Int, available: Int)
    /// `release`: the owner holds no reservation in this ledger.
    case notReserved(PluginIdentity)
}

/// Why a latency change was refused by `LatencyChangePolicy`. Variable latency itself is
/// never a reason: only a number outside its range is. (`LatencyRefusal` is the route
/// latency model's own type.)
enum LatencyChangeRefusal: Error, Hashable, Sendable {
    /// The frames bound is outside `1...RenderNegotiationLimits.maximumFrames`.
    case invalidBound(Int)
    /// The previous latency is outside `0...RenderNegotiationLimits.maximumFrames`.
    case previousOutOfRange(Int)
    /// The new latency is outside `0...bound`.
    case outOfRange(next: Int, bound: Int)
}
