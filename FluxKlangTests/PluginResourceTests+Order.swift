import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The order of the refusals of `ResourceReservation.make`, `ResourceLedger.make` and `ResourceLedger.reserve`, each
/// pair with a fixture holding BOTH defects, and the total order of the reservation owners (#78, PLG6, slice A).
extension PluginResourceTests {
    private static func owner(
        _ subtype: String, _ manufacturer: String, type: String = "aufx", format: PluginFormat = .audioUnitV2
    ) throws -> PluginIdentity {
        try identity(subtype, manufacturer: manufacturer, type: type, format: format)
    }

    private static func owners(_ ledger: ResourceLedger) -> [PluginIdentity] {
        ledger.reservations.map(\.owner)
    }

    private static func attempt(scratch: Int, instances: Int, pinned: Bool = false) throws -> ResourceReservation {
        try ResourceReservation.make(owner: identity(), scratchBytes: scratch, instances: instances, pinned: pinned)
    }

    private static func permutations<Element>(_ items: [Element]) -> [[Element]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[Element]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    /// `low` must come before `high`, whichever of the two is reserved first.
    private static func expectOrder(
        _ low: PluginIdentity, _ high: PluginIdentity, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let base = try ledger()
        let lowItem = try reservation(low, scratch: 1)
        let highItem = try reservation(high, scratch: 2)
        let lowFirst = try base.reserve(lowItem).reserve(highItem)
        let highFirst = try base.reserve(highItem).reserve(lowItem)
        #expect(owners(lowFirst) == [low, high], sourceLocation: sourceLocation)
        #expect(owners(highFirst) == [low, high], sourceLocation: sourceLocation)
        #expect(lowFirst == highFirst, sourceLocation: sourceLocation)
    }

    @Test func aReservationChecksScratchBeforeInstances() {
        let negative = ResourceRefusal.scratchOutOfRange(requested: -1, maximum: 16_777_216)
        #expect(throws: negative) { try Self.attempt(scratch: -1, instances: -1) }
        let tooMuch = ResourceRefusal.scratchOutOfRange(requested: 16_777_217, maximum: 16_777_216)
        #expect(throws: tooMuch) { try Self.attempt(scratch: 16_777_217, instances: 257, pinned: true) }
    }

    @Test func aReservationChecksInstancesBeforeItChecksThatSomethingIsClaimed() {
        let negative = ResourceRefusal.instancesOutOfRange(requested: -1, maximum: 256)
        #expect(throws: negative) { try Self.attempt(scratch: 0, instances: -1) }
        let tooMany = ResourceRefusal.instancesOutOfRange(requested: 257, maximum: 256)
        #expect(throws: tooMany) { try Self.attempt(scratch: 0, instances: 257) }
    }

    @Test func aReservationChecksScratchBeforeItChecksThatSomethingIsClaimed() {
        let negative = ResourceRefusal.scratchOutOfRange(requested: -1, maximum: 16_777_216)
        #expect(throws: negative) { try Self.attempt(scratch: -1, instances: 0) }
        let tooMuch = ResourceRefusal.scratchOutOfRange(requested: 16_777_217, maximum: 16_777_216)
        #expect(throws: tooMuch) { try Self.attempt(scratch: 16_777_217, instances: 0) }
    }

    @Test func aLedgerChecksTheScratchTotalBeforeTheInstanceCapacity() {
        #expect(throws: ResourceRefusal.totalTooSmall(requested: 0)) {
            try ResourceLedger.make(totalScratchBytes: 0, maximumInstances: 0)
        }
        #expect(throws: ResourceRefusal.totalTooSmall(requested: -5)) {
            try ResourceLedger.make(totalScratchBytes: -5, maximumInstances: 257)
        }
        #expect(throws: ResourceRefusal.totalTooLarge(requested: 16_777_217, maximum: 16_777_216)) {
            try ResourceLedger.make(totalScratchBytes: 16_777_217, maximumInstances: 0)
        }
        #expect(throws: ResourceRefusal.totalTooLarge(requested: 16_777_217, maximum: 16_777_216)) {
            try ResourceLedger.make(totalScratchBytes: 16_777_217, maximumInstances: 257)
        }
    }

    @Test func reserveChecksTheOwnerBeforeTheCountOfReservations() throws {
        let full = try Self.sharedFullLedger()
        let held = try Self.pin(100)
        #expect(full.reservations.count == 4_096)
        Self.expectReserveRefused(full, held, .duplicateOwner(held.owner))
    }

    @Test func reserveChecksTheOwnerBeforeScratchAndInstances() throws {
        let held = try Self.identity("Aaaa")
        let base = try Self.ledger(total: 1_000, instances: 4).reserve(Self.reservation(held, scratch: 10))
        let bothShort = try Self.reservation(held, scratch: 2_000, instances: 9)
        Self.expectReserveRefused(base, bothShort, .duplicateOwner(held))
        let scratchShort = try Self.reservation(held, scratch: 2_000)
        Self.expectReserveRefused(base, scratchShort, .duplicateOwner(held))
        let instancesShort = try Self.reservation(held, instances: 9, pinned: true)
        Self.expectReserveRefused(base, instancesShort, .duplicateOwner(held))
    }

    @Test func reserveChecksTheCountOfReservationsBeforeScratch() throws {
        let full = try Self.sharedFullLedger()
        let newcomer = try Self.reservation(Self.indexedIdentity(4_096), scratch: 2_000)
        #expect(full.availableScratchBytes == 1_000)
        Self.expectReserveRefused(full, newcomer, .tooManyReservations(count: 4_097, maximum: 4_096))
    }

    @Test func reserveChecksTheCountOfReservationsBeforeInstances() throws {
        let full = try Self.sharedFullLedger()
        let newcomer = try Self.reservation(Self.indexedIdentity(4_096), instances: 9)
        #expect(full.availableInstances == 8)
        Self.expectReserveRefused(full, newcomer, .tooManyReservations(count: 4_097, maximum: 4_096))
    }

    @Test func reserveChecksScratchBeforeInstances() throws {
        let base = try Self.ledger(total: 1_000, instances: 4)
        let bothShort = try Self.reservation(Self.identity("Aaaa"), scratch: 2_000, instances: 9)
        Self.expectReserveRefused(base, bothShort, .insufficientScratch(needed: 2_000, available: 1_000))
        let instancesOnly = try Self.reservation(Self.identity("Aaaa"), scratch: 1_000, instances: 5)
        Self.expectReserveRefused(base, instancesOnly, .insufficientInstances(needed: 5, available: 4))
    }

    @Test func reserveRefusalsFollowTheLadderOneDefectAtATime() throws {
        let full = try Self.sharedFullLedger()
        let held = try Self.indexedIdentity(7)
        let everything = try Self.reservation(held, scratch: 2_000, instances: 9)
        Self.expectReserveRefused(full, everything, .duplicateOwner(held))
        let newcomer = try Self.indexedIdentity(4_096)
        let noRoom = try Self.reservation(newcomer, scratch: 2_000, instances: 9)
        Self.expectReserveRefused(full, noRoom, .tooManyReservations(count: 4_097, maximum: 4_096))
        let roomForOne = try full.release(owner: Self.indexedIdentity(4_095))
        Self.expectReserveRefused(roomForOne, noRoom, .insufficientScratch(needed: 2_000, available: 1_000))
        let scratchFits = try Self.reservation(newcomer, scratch: 1_000, instances: 9)
        Self.expectReserveRefused(roomForOne, scratchFits, .insufficientInstances(needed: 9, available: 8))
        let fits = try Self.reservation(newcomer, scratch: 1_000, instances: 8)
        let refilled = try roomForOne.reserve(fits)
        #expect(refilled.reservations.count == 4_096)
        #expect(refilled.reservations.last == fits)
        Self.expectInvariants(refilled)
    }

    @Test func reserveInEitherOrderGivesEqualLedgers() throws {
        let base = try Self.ledger(total: 1_000, instances: 8)
        let lowItem = try Self.reservation(Self.owner("Aaaa", "Mkr1"), scratch: 100, instances: 1, pinned: true)
        let highItem = try Self.reservation(Self.owner("Aaaa", "Mkr2"), scratch: 200, instances: 2)
        let lowFirst = try base.reserve(lowItem).reserve(highItem)
        let highFirst = try base.reserve(highItem).reserve(lowItem)
        #expect(lowFirst == highFirst)
        #expect(lowFirst.reservations == [lowItem, highItem])
        #expect(highFirst.reservations == [lowItem, highItem])
        #expect(highFirst.reservedScratchBytes == 300)
        #expect(highFirst.reservedInstances == 3)
    }

    @Test func everyOrderOfFiveOwnersGivesTheSameLedger() throws {
        let first = try Self.owner("Aaaa", "Mkr1")
        let second = try Self.owner("Aaaa", "Mkr2")
        let third = try Self.owner("Bbbb", "Mkr0")
        let fourth = try Self.owner("Aaaa", "Aaaa", type: "aumu")
        let fifth = try Self.owner("Aaaa", "Mkr0", format: .audioUnitV3)
        let items = try [first, second, third, fourth, fifth].enumerated().map { position, owner in
            try Self.reservation(owner, scratch: 10 * (position + 1), instances: position % 2, pinned: position > 2)
        }
        let base = try Self.ledger(total: 1_000, instances: 8)
        let orders = Self.permutations(items)
        #expect(orders.count == 120)
        for order in orders {
            let built = try Self.filled(base, order)
            #expect(Self.owners(built) == [first, second, third, fourth, fifth])
            #expect(built.reservations == items)
            #expect(built.reservedScratchBytes == 150)
            #expect(built.reservedInstances == 2)
        }
    }

    @Test func ownersAreOrderedByFormatBeforeEverythingElse() throws {
        try Self.expectOrder(Self.owner("Zzzz", "Zzzz"), Self.owner("Aaaa", "Aaaa", format: .audioUnitV3))
        try Self.expectOrder(
            Self.owner("Zzzz", "Zzzz", type: "aumu"), Self.owner("Aaaa", "Aaaa", type: "aufx", format: .audioUnitV3)
        )
    }

    @Test func ownersAreOrderedByTypeBeforeSubtypeAndManufacturer() throws {
        try Self.expectOrder(Self.owner("Zzzz", "Zzzz"), Self.owner("Aaaa", "Aaaa", type: "aumu"))
        try Self.expectOrder(Self.owner("Zzzz", "Zzzz", type: "aumi"), Self.owner("Aaaa", "Aaaa", type: "aumu"))
        try Self.expectOrder(Self.owner("Same", "Zzzz"), Self.owner("Same", "Aaaa", type: "aumu"))
    }

    @Test func ownersAreOrderedBySubtypeBeforeManufacturer() throws {
        try Self.expectOrder(Self.owner("Aaaa", "Zzzz"), Self.owner("Bbbb", "Aaaa"))
        try Self.expectOrder(Self.owner("Zzzz", "Mkr1"), Self.owner("aaaa", "Mkr1"))
    }

    @Test func ownersAreOrderedByManufacturerWhenNothingElseDiffers() throws {
        try Self.expectOrder(Self.owner("Aaaa", "Aaaa"), Self.owner("Aaaa", "Bbbb"))
        try Self.expectOrder(Self.owner("Aaaa", "ZZZZ"), Self.owner("Aaaa", "aaaa"))
    }

    @Test func theOwnerOrderIsAStrictTotalOrderAgreeingWithItsKeys() throws {
        var sample: [PluginIdentity] = []
        for format in [PluginFormat.audioUnitV2, .audioUnitV3] {
            for type in ["aufx", "aumu"] {
                for subtype in ["Aaaa", "Bbbb"] {
                    for manufacturer in ["Mkr1", "Mkr2"] {
                        try sample.append(Self.owner(subtype, manufacturer, type: type, format: format))
                    }
                }
            }
        }
        #expect(sample.count == 16)
        let order = PluginIdentity.resourceOrder
        let key = Self.orderKey
        #expect(sample.allSatisfy { !order($0, $0) })
        let pairs = sample.flatMap { left in sample.map { (left, $0) } }
        #expect(pairs.filter { $0.0 != $0.1 }.allSatisfy { order($0.0, $0.1) != order($0.1, $0.0) })
        #expect(pairs.allSatisfy { order($0.0, $0.1) == key($0.0).lexicographicallyPrecedes(key($0.1)) })
        let transitive = sample.allSatisfy { first in
            sample.allSatisfy { second in
                sample.allSatisfy { third in
                    !(order(first, second) && order(second, third)) || order(first, third)
                }
            }
        }
        #expect(transitive)
    }

    @Test func aReservationLandsAtTheFrontTheMiddleAndTheEnd() throws {
        var ledger = try Self.ledger(total: 1_000, instances: 8)
        for index in [2, 4, 6] {
            ledger = try ledger.reserve(Self.reservation(Self.indexedIdentity(index), scratch: 1))
        }
        let steps = [
            (0, [0, 2, 4, 6]), (5, [0, 2, 4, 5, 6]), (7, [0, 2, 4, 5, 6, 7]),
            (1, [0, 1, 2, 4, 5, 6, 7]), (3, [0, 1, 2, 3, 4, 5, 6, 7])
        ]
        for (index, expected) in steps {
            ledger = try ledger.reserve(Self.reservation(Self.indexedIdentity(index), scratch: 1))
            let expectedOwners = try expected.map { try Self.indexedIdentity($0) }
            #expect(Self.owners(ledger) == expectedOwners)
            Self.expectInvariants(ledger)
        }
    }
}
