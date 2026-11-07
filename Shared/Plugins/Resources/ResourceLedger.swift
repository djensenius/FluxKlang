//
//  ResourceLedger.swift
//  FluxKlang
//
//  A bounded ledger of plugin resource reservations (#78, slice PLG6). Value in, value
//  out: `reserve` and `release` return a new ledger or throw a typed `ResourceRefusal`,
//  and a refused call changes nothing. Reservations are kept in a fixed total order of
//  their owners, so the same set of reservations is always the same ledger, whatever
//  order they were reserved in. No clock, scan, load or Audio Unit call.
//

/// The scratch bytes and instance slots reserved so far, against fixed totals.
///
/// Invariants (all re-established by every transition, none can be broken from outside the
/// file): `reservations` is strictly ascending by `PluginIdentity.resourceOrder` with unique
/// owners and at most `ResourceLimits.maximumReservations` entries; `reservedScratchBytes`
/// and `reservedInstances` are the sums over `reservations` and never exceed the totals.
struct ResourceLedger: Equatable, Sendable {
    let totalScratchBytes: Int
    let maximumInstances: Int
    let reservations: [ResourceReservation]
    let reservedScratchBytes: Int
    let reservedInstances: Int

    var availableScratchBytes: Int { totalScratchBytes - reservedScratchBytes }
    var availableInstances: Int { maximumInstances - reservedInstances }

    private init(
        totalScratchBytes: Int, maximumInstances: Int, reservations: [ResourceReservation],
        reservedScratchBytes: Int, reservedInstances: Int
    ) {
        self.totalScratchBytes = totalScratchBytes
        self.maximumInstances = maximumInstances
        self.reservations = reservations
        self.reservedScratchBytes = reservedScratchBytes
        self.reservedInstances = reservedInstances
    }

    /// An empty ledger. Checks, in this order: the scratch total is `1...maximumScratchBytes`
    /// (`.totalTooSmall` below, `.totalTooLarge` above), then the instance capacity is
    /// `1...maximumInstances` (`.instanceCapacityTooSmall`, `.instanceCapacityTooLarge`).
    static func make(
        totalScratchBytes: Int, maximumInstances: Int
    ) throws(ResourceRefusal) -> ResourceLedger {
        guard totalScratchBytes >= 1 else { throw .totalTooSmall(requested: totalScratchBytes) }
        guard totalScratchBytes <= ResourceLimits.maximumScratchBytes else {
            throw .totalTooLarge(requested: totalScratchBytes, maximum: ResourceLimits.maximumScratchBytes)
        }
        guard maximumInstances >= 1 else { throw .instanceCapacityTooSmall(requested: maximumInstances) }
        guard maximumInstances <= ResourceLimits.maximumInstances else {
            throw .instanceCapacityTooLarge(requested: maximumInstances, maximum: ResourceLimits.maximumInstances)
        }
        return ResourceLedger(
            totalScratchBytes: totalScratchBytes, maximumInstances: maximumInstances, reservations: [],
            reservedScratchBytes: 0, reservedInstances: 0
        )
    }

    func reservation(for owner: PluginIdentity) -> ResourceReservation? {
        reservations.first { $0.owner == owner }
    }

    /// The ledger with `reservation` added. Refusals, checked in this order:
    /// `.duplicateOwner` (the owner already holds one, whatever its amounts or pin),
    /// `.tooManyReservations` (the ledger already holds `maximumReservations`),
    /// `.insufficientScratch`, then `.insufficientInstances`. A reservation of exactly the
    /// remaining scratch or instances fits; one more does not.
    func reserve(_ reservation: ResourceReservation) throws(ResourceRefusal) -> ResourceLedger {
        guard !reservations.contains(where: { $0.owner == reservation.owner }) else {
            throw .duplicateOwner(reservation.owner)
        }
        guard reservations.count < ResourceLimits.maximumReservations else {
            throw .tooManyReservations(count: reservations.count + 1, maximum: ResourceLimits.maximumReservations)
        }
        guard let scratch = Self.checkedSum(reservedScratchBytes, reservation.scratchBytes),
              scratch <= totalScratchBytes
        else {
            throw .insufficientScratch(needed: reservation.scratchBytes, available: availableScratchBytes)
        }
        guard let instances = Self.checkedSum(reservedInstances, reservation.instances),
              instances <= maximumInstances
        else {
            throw .insufficientInstances(needed: reservation.instances, available: availableInstances)
        }
        var next = reservations
        next.insert(reservation, at: insertionIndex(for: reservation.owner))
        return ResourceLedger(
            totalScratchBytes: totalScratchBytes, maximumInstances: maximumInstances, reservations: next,
            reservedScratchBytes: scratch, reservedInstances: instances
        )
    }

    /// The ledger without `owner`'s reservation, pinned or not: an explicit release is the only
    /// way a reservation leaves a ledger. `.notReserved` when the owner holds none.
    func release(owner: PluginIdentity) throws(ResourceRefusal) -> ResourceLedger {
        guard let index = reservations.firstIndex(where: { $0.owner == owner }) else {
            throw .notReserved(owner)
        }
        var next = reservations
        let released = next.remove(at: index)
        return ResourceLedger(
            totalScratchBytes: totalScratchBytes, maximumInstances: maximumInstances, reservations: next,
            reservedScratchBytes: reservedScratchBytes - released.scratchBytes,
            reservedInstances: reservedInstances - released.instances
        )
    }

    /// `nil` when the sum overflows `Int`. Every sum of reserved bytes and instances goes through here.
    static func checkedSum(_ lhs: Int, _ rhs: Int) -> Int? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    /// The first position whose owner does not precede `owner`: where `owner` keeps the order.
    private func insertionIndex(for owner: PluginIdentity) -> Int {
        reservations.firstIndex { !PluginIdentity.resourceOrder($0.owner, owner) } ?? reservations.count
    }
}

extension PluginIdentity {
    /// A total order over identities, built from the identity's own fields and never from
    /// `Hashable` (whose order changes from run to run): `format` (`au2` before `au3`), then
    /// `type`, `subtype`, `manufacturer` by unsigned code value, then `kind` by raw value.
    /// `kind` is derived from `type`, so the last key never separates two identities; it is
    /// kept so the order names every field of the identity.
    static func resourceOrder(_ lhs: PluginIdentity, _ rhs: PluginIdentity) -> Bool {
        if lhs.format != rhs.format { return lhs.format.rawValue < rhs.format.rawValue }
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        if lhs.subtype != rhs.subtype { return lhs.subtype < rhs.subtype }
        if lhs.manufacturer != rhs.manufacturer { return lhs.manufacturer < rhs.manufacturer }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}
