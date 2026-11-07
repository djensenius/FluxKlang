//
//  ResourceReservation.swift
//  FluxKlang
//
//  One plugin's claim on the shared render resources (#78, slice PLG6): scratch bytes
//  and instance slots, optionally pinned. A reservation exists only if it passed
//  `make`. Pure values: nothing here loads, scans or instantiates a plugin.
//

/// Resource policy of this slice, not Apple limits. Byte counts are `Int` bytes.
enum ResourceLimits {
    /// Largest scratch total a ledger or one reservation may name (the render scratch arena).
    static let maximumScratchBytes = RenderNegotiationLimits.scratchBytes
    static let maximumInstances = 256
    /// Reservations one ledger holds (the catalog entry cap).
    static let maximumReservations = PluginCatalogLimits.entries
}

struct ResourceReservation: Hashable, Sendable {
    let owner: PluginIdentity
    let scratchBytes: Int
    let instances: Int
    /// A pinned reservation is a shared instance that stays until `ResourceLedger.release(owner:)`
    /// names it. No pressure decision releases any reservation, pinned or not.
    let pinned: Bool

    private init(owner: PluginIdentity, scratchBytes: Int, instances: Int, pinned: Bool) {
        self.owner = owner
        self.scratchBytes = scratchBytes
        self.instances = instances
        self.pinned = pinned
    }

    /// Checks, in this order: scratch bytes in `0...maximumScratchBytes`, instances in
    /// `0...maximumInstances`, then that something is claimed. A reservation with no scratch and no
    /// instances is a pure pin: legal when `pinned`, otherwise `.emptyReservation`.
    static func make(
        owner: PluginIdentity, scratchBytes: Int, instances: Int, pinned: Bool
    ) throws(ResourceRefusal) -> ResourceReservation {
        guard (0...ResourceLimits.maximumScratchBytes).contains(scratchBytes) else {
            throw .scratchOutOfRange(requested: scratchBytes, maximum: ResourceLimits.maximumScratchBytes)
        }
        guard (0...ResourceLimits.maximumInstances).contains(instances) else {
            throw .instancesOutOfRange(requested: instances, maximum: ResourceLimits.maximumInstances)
        }
        guard scratchBytes > 0 || instances > 0 || pinned else { throw .emptyReservation }
        return ResourceReservation(owner: owner, scratchBytes: scratchBytes, instances: instances, pinned: pinned)
    }
}
