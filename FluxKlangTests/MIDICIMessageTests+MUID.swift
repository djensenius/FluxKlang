//
//  MIDICIMessageTests+MUID.swift
//  FluxKlangTests
//
//  The 28-bit MUID value and the deterministic allocator (#83, slice CI1).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    @Test func aMUIDIsAssignableFromZeroToTheMaximumOrIsTheBroadcastAndNothingElse() throws {
        for raw: UInt32 in [0, 1, 0x7F, 0x80, 0x0123_4567, 0x0FFF_FEFE, 0x0FFF_FEFF, 0x0FFF_FFFF] {
            #expect(try Self.muid(raw).rawValue == raw)
        }
        for raw: UInt32 in [0x0FFF_FF00, 0x0FFF_FF01, 0x0FFF_FFAB, 0x0FFF_FFFE, 0x1000_0000, 0x8000_0000, .max] {
            #expect(throws: MIDICIRefusal.invalidMUID(raw)) { try MIDICIMUID.make(raw) }
        }
    }

    @Test func onlyTheAllOnesMUIDIsTheBroadcast() throws {
        #expect(MIDICIMUID.broadcast.rawValue == 0x0FFF_FFFF)
        #expect(try Self.muid(0x0FFF_FFFF).isBroadcast)
        #expect(try Self.muid(0x0FFF_FFFF) == MIDICIMUID.broadcast)
        #expect(try !Self.muid(0x0FFF_FEFF).isBroadcast)
        #expect(try !Self.muid(0).isBroadcast)
    }

    @Test func aMUIDOrdersAndHashesByItsRawValue() throws {
        let low = try Self.muid(5)
        let high = try Self.muid(0x0FFF_FEFF)
        #expect(low < high && !(high < low) && !(low < low))
        #expect(Set([low, high, try Self.muid(5)]).count == 2)
        #expect([high, MIDICIMUID.broadcast, low].sorted() == [low, high, MIDICIMUID.broadcast])
    }

    @Test func allocateReturnsTheFirstFreeCandidateInTheCallersOrder() throws {
        let inUse = Set([try Self.muid(7)])
        #expect(try MIDICIMUID.allocate(candidates: [9, 3, 8], inUse: inUse).rawValue == 9)
        #expect(try MIDICIMUID.allocate(candidates: [8, 3, 9], inUse: inUse).rawValue == 8)
        #expect(try MIDICIMUID.allocate(candidates: [7, 3, 9], inUse: inUse).rawValue == 3)
        #expect(try MIDICIMUID.allocate(candidates: [7, 7, 9], inUse: inUse).rawValue == 9)
        #expect(try MIDICIMUID.allocate(candidates: [9, 9], inUse: []).rawValue == 9)
    }

    @Test func allocateSkipsReservedBroadcastAndOverwideCandidates() throws {
        let candidates: [UInt32] = [0x0FFF_FFFF, 0x0FFF_FF00, 0x0FFF_FFFE, 0x1000_0000, .max, 0x0FFF_FEFF, 4]
        #expect(try MIDICIMUID.allocate(candidates: candidates, inUse: []).rawValue == 0x0FFF_FEFF)
        let used = Set([try Self.muid(0x0FFF_FEFF)])
        #expect(try MIDICIMUID.allocate(candidates: candidates, inUse: used).rawValue == 4)
        #expect(try MIDICIMUID.allocate(candidates: [0, 0x0FFF_FFFF], inUse: []).rawValue == 0)
    }

    @Test func allocateRefusesWhenNoCandidateIsFree() throws {
        #expect(throws: MIDICIRefusal.noFreeMUID) { try MIDICIMUID.allocate(candidates: [], inUse: []) }
        let used = Set([try Self.muid(1), try Self.muid(2)])
        #expect(throws: MIDICIRefusal.noFreeMUID) { try MIDICIMUID.allocate(candidates: [1, 2, 1], inUse: used) }
        #expect(throws: MIDICIRefusal.noFreeMUID) {
            try MIDICIMUID.allocate(candidates: [0x0FFF_FFFF, 0x0FFF_FF10, 0x2000_0000], inUse: [])
        }
    }

    @Test func allocateSkipsEveryCandidateInUseWhicheverOfThemComesFirst() throws {
        let candidates: [UInt32] = [3, 4, 5]
        let inUse = Set([try Self.muid(3)])
        #expect(try MIDICIMUID.allocate(candidates: candidates, inUse: inUse).rawValue == 4)
        #expect(try MIDICIMUID.allocate(candidates: candidates, inUse: inUse.union([try Self.muid(5)])).rawValue == 4)
        #expect(try MIDICIMUID.allocate(candidates: candidates, inUse: inUse.union([try Self.muid(4)])).rawValue == 5)
        #expect(throws: MIDICIRefusal.noFreeMUID) { try MIDICIMUID.allocate(candidates: [3], inUse: inUse) }
    }
}
