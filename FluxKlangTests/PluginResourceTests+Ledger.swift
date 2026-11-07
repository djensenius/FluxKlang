import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Reservations, ledger bounds, `reserve`, `release` and the arithmetic behind them (#78, PLG6, slice A).
extension PluginResourceTests {
    @Test func reservationStoresEveryFieldItWasGiven() throws {
        let owner = try Self.identity("Stor", manufacturer: "Maks", type: "aumu", format: .audioUnitV3)
        let held = try Self.reservation(owner, scratch: 12_345, instances: 7, pinned: true)
        #expect(held.owner == owner)
        #expect(held.scratchBytes == 12_345)
        #expect(held.instances == 7)
        #expect(held.pinned)
        let loose = try Self.reservation(owner, scratch: 1, instances: 3, pinned: false)
        #expect(loose.scratchBytes == 1)
        #expect(loose.instances == 3)
        #expect(!loose.pinned)
        #expect(loose != held)
    }

    @Test func reservationAcceptsZeroAndTheMaximumScratch() throws {
        let owner = try Self.identity()
        let none = try Self.reservation(owner, scratch: 0, instances: 1)
        #expect(none.scratchBytes == 0)
        let most = try Self.reservation(owner, scratch: 16_777_216, instances: 0)
        #expect(most.scratchBytes == 16_777_216)
        #expect(most.instances == 0)
    }

    @Test func reservationRefusesScratchOutsideZeroToTheMaximum() throws {
        let owner = try Self.identity()
        for bad in [16_777_217, -1, Int.max, Int.min] {
            #expect(throws: ResourceRefusal.scratchOutOfRange(requested: bad, maximum: 16_777_216)) {
                try Self.reservation(owner, scratch: bad, instances: 1)
            }
        }
    }

    @Test func reservationAcceptsZeroAndTheMaximumInstances() throws {
        let owner = try Self.identity()
        let none = try Self.reservation(owner, scratch: 1, instances: 0)
        #expect(none.instances == 0)
        let most = try Self.reservation(owner, scratch: 0, instances: 256)
        #expect(most.instances == 256)
        #expect(most.scratchBytes == 0)
    }

    @Test func reservationRefusesInstancesOutsideZeroToTheMaximum() throws {
        let owner = try Self.identity()
        for bad in [257, -1, Int.max, Int.min] {
            #expect(throws: ResourceRefusal.instancesOutOfRange(requested: bad, maximum: 256)) {
                try Self.reservation(owner, scratch: 1, instances: bad)
            }
        }
    }

    @Test func aReservationClaimingNothingIsRefusedUnlessPinned() throws {
        let owner = try Self.identity()
        #expect(throws: ResourceRefusal.emptyReservation) { try Self.reservation(owner) }
        let purePin = try Self.reservation(owner, pinned: true)
        #expect(purePin.scratchBytes == 0)
        #expect(purePin.instances == 0)
        #expect(purePin.pinned)
        #expect(try Self.reservation(owner, scratch: 1).scratchBytes == 1)
        #expect(try Self.reservation(owner, instances: 1).instances == 1)
    }

    @Test func ledgerMakeAcceptsTheSmallestAndLargestTotals() throws {
        let small = try Self.ledger(total: 1, instances: 1)
        #expect(small.totalScratchBytes == 1)
        #expect(small.maximumInstances == 1)
        #expect(small.reservations.isEmpty)
        #expect(small.reservedScratchBytes == 0)
        #expect(small.reservedInstances == 0)
        #expect(small.availableScratchBytes == 1)
        #expect(small.availableInstances == 1)
        let large = try Self.ledger(total: 16_777_216, instances: 256)
        #expect(large.totalScratchBytes == 16_777_216)
        #expect(large.maximumInstances == 256)
        #expect(large.availableScratchBytes == 16_777_216)
        #expect(large.availableInstances == 256)
    }

    @Test func ledgerMakeRefusesTotalsOutsideItsRange() throws {
        for bad in [0, -1, Int.min] {
            #expect(throws: ResourceRefusal.totalTooSmall(requested: bad)) { try Self.ledger(total: bad) }
        }
        for bad in [16_777_217, Int.max] {
            #expect(throws: ResourceRefusal.totalTooLarge(requested: bad, maximum: 16_777_216)) {
                try Self.ledger(total: bad)
            }
        }
    }

    @Test func ledgerMakeAcceptsOneAndTheMaximumInstanceCapacity() throws {
        #expect(try Self.ledger(total: 10, instances: 1).maximumInstances == 1)
        #expect(try Self.ledger(total: 10, instances: 256).maximumInstances == 256)
        #expect(try Self.ledger(total: 10, instances: 256).availableInstances == 256)
    }

    @Test func ledgerMakeRefusesInstanceCapacityOutsideItsRange() throws {
        for bad in [0, -1, Int.min] {
            #expect(throws: ResourceRefusal.instanceCapacityTooSmall(requested: bad)) {
                try Self.ledger(total: 10, instances: bad)
            }
        }
        for bad in [257, Int.max] {
            #expect(throws: ResourceRefusal.instanceCapacityTooLarge(requested: bad, maximum: 256)) {
                try Self.ledger(total: 10, instances: bad)
            }
        }
    }

    @Test func reserveAddsReservationsAndKeepsTheSums() throws {
        let base = try Self.ledger(total: 1_000, instances: 8)
        let first = try Self.reservation(Self.identity("Aaaa"), scratch: 300, instances: 2)
        let second = try Self.reservation(Self.identity("Bbbb"), scratch: 200, instances: 3, pinned: true)
        let afterFirst = try base.reserve(first)
        #expect(afterFirst.reservations == [first])
        #expect(afterFirst.reservedScratchBytes == 300)
        #expect(afterFirst.reservedInstances == 2)
        #expect(afterFirst.availableScratchBytes == 700)
        #expect(afterFirst.availableInstances == 6)
        let afterSecond = try afterFirst.reserve(second)
        #expect(afterSecond.reservations == [first, second])
        #expect(afterSecond.reservedScratchBytes == 500)
        #expect(afterSecond.reservedInstances == 5)
        #expect(afterSecond.availableScratchBytes == 500)
        #expect(afterSecond.availableInstances == 3)
        #expect(afterSecond.totalScratchBytes == 1_000)
        #expect(afterSecond.maximumInstances == 8)
        #expect(afterSecond.reservation(for: first.owner) == first)
        #expect(afterSecond.reservation(for: second.owner) == second)
        #expect(try afterSecond.reservation(for: Self.identity("Cccc")) == nil)
        #expect(base.reservations.isEmpty)
        Self.expectInvariants(afterSecond)
    }

    @Test func reserveAcceptsExactlyTheRemainingScratch() throws {
        let base = try Self.filled(Self.ledger(), [Self.reservation(Self.identity("Aaaa"), scratch: 600)])
        let exact = try Self.reservation(Self.identity("Bbbb"), scratch: 400)
        let full = try base.reserve(exact)
        #expect(full.reservedScratchBytes == 1_000)
        #expect(full.availableScratchBytes == 0)
        let over = try Self.reservation(Self.identity("Bbbb"), scratch: 401)
        Self.expectReserveRefused(base, over, .insufficientScratch(needed: 401, available: 400))
        let one = try Self.reservation(Self.identity("Cccc"), scratch: 1)
        Self.expectReserveRefused(full, one, .insufficientScratch(needed: 1, available: 0))
    }

    @Test func reserveAcceptsExactlyTheRemainingInstances() throws {
        let base = try Self.filled(Self.ledger(), [Self.reservation(Self.identity("Aaaa"), instances: 5)])
        let exact = try Self.reservation(Self.identity("Bbbb"), instances: 3)
        let full = try base.reserve(exact)
        #expect(full.reservedInstances == 8)
        #expect(full.availableInstances == 0)
        let over = try Self.reservation(Self.identity("Bbbb"), instances: 4)
        Self.expectReserveRefused(base, over, .insufficientInstances(needed: 4, available: 3))
        let one = try Self.reservation(Self.identity("Cccc"), instances: 1)
        Self.expectReserveRefused(full, one, .insufficientInstances(needed: 1, available: 0))
    }

    @Test func reserveRefusalsCarryTheirOwnNumbers() throws {
        let held = try Self.reservation(Self.identity("Aaaa"), scratch: 1_234, instances: 6)
        let base = try Self.filled(Self.ledger(total: 5_000, instances: 20), [held])
        let tooMuchScratch = try Self.reservation(Self.identity("Bbbb"), scratch: 4_000, instances: 1)
        Self.expectReserveRefused(base, tooMuchScratch, .insufficientScratch(needed: 4_000, available: 3_766))
        let tooManyInstances = try Self.reservation(Self.identity("Bbbb"), scratch: 10, instances: 15)
        Self.expectReserveRefused(base, tooManyInstances, .insufficientInstances(needed: 15, available: 14))
    }

    @Test func reserveRefusesAnOwnerThatAlreadyHoldsAReservation() throws {
        let owner = try Self.identity("Dupe")
        let base = try Self.filled(Self.ledger(), [Self.reservation(owner, scratch: 100, instances: 1)])
        let same = try Self.reservation(owner, scratch: 100, instances: 1)
        Self.expectReserveRefused(base, same, .duplicateOwner(owner))
        let other = try Self.reservation(owner, scratch: 1, instances: 0, pinned: true)
        Self.expectReserveRefused(base, other, .duplicateOwner(owner))
        let pin = try Self.reservation(owner, pinned: true)
        Self.expectReserveRefused(base, pin, .duplicateOwner(owner))
    }

    @Test func ownersThatDifferInAnySingleFieldAreDistinctOwners() throws {
        let base = try Self.identity("Aaaa", manufacturer: "Maks", type: "aufx", format: .audioUnitV2)
        let others = try [
            Self.identity("Aaab", manufacturer: "Maks", type: "aufx", format: .audioUnitV2),
            Self.identity("Aaaa", manufacturer: "Maky", type: "aufx", format: .audioUnitV2),
            Self.identity("Aaaa", manufacturer: "Maks", type: "aumu", format: .audioUnitV2),
            Self.identity("Aaaa", manufacturer: "Maks", type: "aufx", format: .audioUnitV3)
        ]
        var ledger = try Self.filled(Self.ledger(), [Self.reservation(base, scratch: 1)])
        for other in others { ledger = try ledger.reserve(Self.reservation(other, scratch: 1)) }
        #expect(ledger.reservations.count == 5)
        #expect(ledger.reservedScratchBytes == 5)
        Self.expectInvariants(ledger)
    }

    @Test func aLedgerHoldsExactlyFourThousandNinetySixReservations() throws {
        let full = try Self.sharedFullLedger()
        #expect(full.reservations.count == 4_096)
        #expect(full.reservedScratchBytes == 0)
        #expect(full.reservedInstances == 0)
        Self.expectInvariants(full)
        let extra = try Self.pin(4_096)
        Self.expectReserveRefused(full, extra, .tooManyReservations(count: 4_097, maximum: 4_096))
        let almost = try full.release(owner: Self.indexedIdentity(4_095))
        #expect(almost.reservations.count == 4_095)
        #expect(try almost.reserve(extra).reservations.count == 4_096)
    }

    @Test func releaseRemovesTheReservationAndGivesItsAmountsBack() throws {
        let one = try Self.reservation(Self.identity("Aaaa"), scratch: 300, instances: 2)
        let two = try Self.reservation(Self.identity("Bbbb"), scratch: 200, instances: 3, pinned: true)
        let three = try Self.reservation(Self.identity("Cccc"), scratch: 50, instances: 1)
        let all = try Self.filled(Self.ledger(), [one, two, three])
        let without = try all.release(owner: two.owner)
        #expect(without.reservations == [one, three])
        #expect(without.reservedScratchBytes == 350)
        #expect(without.reservedInstances == 3)
        #expect(without.availableScratchBytes == 650)
        #expect(without.availableInstances == 5)
        #expect(without.reservation(for: two.owner) == nil)
        #expect(try without == Self.filled(Self.ledger(), [one, three]))
        Self.expectInvariants(without)
    }

    @Test func releaseRefusesAnOwnerThatHoldsNothing() throws {
        let held = try Self.identity("Held")
        let base = try Self.filled(Self.ledger(), [Self.reservation(held, scratch: 5)])
        let stranger = try Self.identity("Nope")
        Self.expectReleaseRefused(base, stranger, .notReserved(stranger))
        Self.expectReleaseRefused(try Self.ledger(), held, .notReserved(held))
        let released = try base.release(owner: held)
        Self.expectReleaseRefused(released, held, .notReserved(held))
    }

    @Test func aPinnedReservationLeavesTheLedgerOnlyWhenItsOwnerIsReleased() throws {
        let pinned = try Self.reservation(Self.identity("Pinn"), scratch: 400, instances: 2, pinned: true)
        let loose = try Self.reservation(Self.identity("Loos"), scratch: 100, instances: 1)
        let both = try Self.filled(Self.ledger(), [pinned, loose])
        let afterLoose = try both.release(owner: loose.owner)
        #expect(afterLoose.reservations == [pinned])
        #expect(afterLoose.reservation(for: pinned.owner)?.pinned == true)
        #expect(afterLoose.reservedScratchBytes == 400)
        let afterPinned = try afterLoose.release(owner: pinned.owner)
        #expect(try afterPinned == Self.ledger())
    }

    @Test func aPurePinTakesASlotButNoScratchOrInstances() throws {
        let owner = try Self.identity("Pure")
        let pin = try Self.reservation(owner, pinned: true)
        let pinnedLedger = try Self.ledger(total: 1, instances: 1).reserve(pin)
        #expect(pinnedLedger.reservations == [pin])
        #expect(pinnedLedger.reservedScratchBytes == 0)
        #expect(pinnedLedger.reservedInstances == 0)
        #expect(pinnedLedger.availableScratchBytes == 1)
        #expect(pinnedLedger.availableInstances == 1)
        let more = try pinnedLedger.reserve(Self.reservation(Self.identity("More"), scratch: 1, instances: 1))
        #expect(more.availableScratchBytes == 0)
        #expect(more.availableInstances == 0)
        #expect(try more.release(owner: owner).reservations.count == 1)
    }

    @Test func releasingWhatWasJustReservedRestoresTheEarlierLedger() throws {
        let first = try Self.reservation(Self.identity("Aaaa"), scratch: 10, instances: 1)
        let base = try Self.filled(Self.ledger(), [first])
        let item = try Self.reservation(Self.identity("Bbbb"), scratch: 20, instances: 2, pinned: true)
        #expect(try base.reserve(item).release(owner: item.owner) == base)
    }

    @Test func theLargestLedgerTakesOneReservationOfEverythingAndNothingMore() throws {
        let base = try Self.ledger(total: 16_777_216, instances: 256)
        let everything = try Self.reservation(Self.identity("Aaaa"), scratch: 16_777_216, instances: 256)
        let full = try base.reserve(everything)
        #expect(full.reservedScratchBytes == 16_777_216)
        #expect(full.reservedInstances == 256)
        #expect(full.availableScratchBytes == 0)
        #expect(full.availableInstances == 0)
        let moreScratch = try Self.reservation(Self.identity("Bbbb"), scratch: 1)
        Self.expectReserveRefused(full, moreScratch, .insufficientScratch(needed: 1, available: 0))
        let moreInstances = try Self.reservation(Self.identity("Bbbb"), instances: 1)
        Self.expectReserveRefused(full, moreInstances, .insufficientInstances(needed: 1, available: 0))
        let half = try Self.reservation(Self.identity("Cccc"), scratch: 8_388_608, instances: 128)
        let otherHalf = try Self.reservation(Self.identity("Dddd"), scratch: 8_388_608, instances: 128)
        let twoHalves = try base.reserve(half).reserve(otherHalf)
        #expect(twoHalves.availableScratchBytes == 0)
        #expect(twoHalves.availableInstances == 0)
    }

    @Test func checkedSumReportsAnOverflowInsteadOfWrapping() {
        #expect(ResourceLedger.checkedSum(1, 2) == 3)
        #expect(ResourceLedger.checkedSum(0, 0) == 0)
        #expect(ResourceLedger.checkedSum(-4, 4) == 0)
        #expect(ResourceLedger.checkedSum(Int.max, 0) == Int.max)
        #expect(ResourceLedger.checkedSum(Int.max - 1, 1) == Int.max)
        #expect(ResourceLedger.checkedSum(Int.max, 1) == nil)
        #expect(ResourceLedger.checkedSum(1, Int.max) == nil)
        #expect(ResourceLedger.checkedSum(Int.min, -1) == nil)
        #expect(ResourceLedger.checkedSum(Int.min, Int.max) == -1)
    }

    @Test func everyTransitionKeepsTheLedgerInvariants() throws {
        var ledger = try Self.ledger(total: 10_000, instances: 40)
        for index in [5, 3, 9, 1, 7, 2, 8, 0, 6, 4] {
            let owner = try Self.indexedIdentity(index)
            let item = try Self.reservation(owner, scratch: 100 + index, instances: index % 3, pinned: index % 2 == 0)
            ledger = try ledger.reserve(item)
            Self.expectInvariants(ledger)
        }
        #expect(ledger.reservations.count == 10)
        #expect(ledger.reservedScratchBytes == 1_045)
        #expect(ledger.reservedInstances == 9)
        for index in [3, 0, 9, 4] {
            ledger = try ledger.release(owner: Self.indexedIdentity(index))
            Self.expectInvariants(ledger)
        }
        #expect(ledger.reservations.count == 6)
        #expect(ledger.reservedScratchBytes == 629)
        #expect(ledger.reservedInstances == 8)
    }
}
