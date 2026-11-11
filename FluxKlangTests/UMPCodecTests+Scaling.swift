import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("MIDI 1↔2 scaling", .productionAccessAudit)
#else
@Suite("MIDI 1↔2 scaling")
#endif
struct UMPScalingTests {
    static func up(_ value: UInt32, _ from: Int, _ to: Int) throws -> UInt32 {
        try UMPScaling.scaleUp(value, fromBits: from, toBits: to)
    }

    static func down(_ value: UInt32, _ from: Int, _ to: Int) throws -> UInt32 {
        try UMPScaling.scaleDown(value, fromBits: from, toBits: to)
    }

    @Test func contractVectors() throws {
        // media-contract §9.3.
        #expect(try Self.up(100, 7, 16) == 0xC924)
        #expect(try Self.up(64, 7, 32) == 0x8000_0000)
    }

    @Test func referenceValues() throws {
        #expect(try Self.up(100, 7, 32) == 0xC924_9249)
        #expect(try Self.up(65, 7, 16) == 0x8208)
        #expect(try Self.up(1, 7, 16) == 0x0200)
        #expect(try Self.up(65, 7, 14) == 0x2082)
        #expect(try Self.up(8193, 14, 32) == 0x8004_0020)
        #expect(try Self.up(8193, 14, 16) == 0x8004)
        #expect(try Self.up(200, 8, 16) == 0xC891)
        #expect(try Self.up(3, 2, 8) == 0xFF)
    }

    @Test func minimumCentreAndMaximumMapToTheirCounterparts() throws {
        for (from, to) in [(7, 14), (7, 16), (7, 32), (14, 16), (14, 32), (16, 32), (2, 32), (31, 32)] {
            let maxIn = UInt32((UInt64(1) << UInt64(from)) - 1)
            let maxOut = UInt32((UInt64(1) << UInt64(to)) - 1)
            #expect(try Self.up(0, from, to) == 0)
            #expect(try Self.up(UInt32(1) << UInt32(from - 1), from, to) == UInt32(1) << UInt32(to - 1))
            #expect(try Self.up(maxIn, from, to) == maxOut, "\(from)→\(to)")
            #expect(try Self.down(maxOut, to, from) == maxIn)
        }
    }

    @Test func sevenBitRoundTripsExhaustively() throws {
        for to in [8, 14, 16, 32] {
            var previous: UInt32?
            for value in UInt32(0)...127 {
                let scaled = try Self.up(value, 7, to)
                #expect(try Self.down(scaled, to, 7) == value, "7→\(to) \(value)")
                if let previous { #expect(scaled > previous) }
                previous = scaled
            }
        }
    }

    @Test func fourteenBitRoundTripsExhaustively() throws {
        for to in [16, 32] {
            var previous: UInt32?
            var failures = 0
            for value in UInt32(0)...0x3FFF {
                let scaled = try Self.up(value, 14, to)
                if try Self.down(scaled, to, 14) != value || previous.map({ scaled <= $0 }) == true { failures += 1 }
                previous = scaled
            }
            #expect(failures == 0, "14→\(to)")
        }
    }

    @Test func upscaleAboveCentreIsNotAPlainShift() throws {
        // A plain shift would give 0xC800 and 0xFE00; only values above the centre repeat bits.
        #expect(try Self.up(100, 7, 16) != 100 << 9)
        #expect(try Self.up(127, 7, 16) == 0xFFFF)
        #expect(try Self.up(64, 7, 16) == 64 << 9)
        #expect(try Self.up(63, 7, 16) == 63 << 9)
    }

    @Test func downscaleIsARightShift() throws {
        #expect(try Self.down(0xC924, 16, 7) == 100)
        #expect(try Self.down(0xC9FF, 16, 7) == 100)
        #expect(try Self.down(0x8000_0000, 32, 7) == 64)
        #expect(try Self.down(0xFFFF_FFFF, 32, 14) == 0x3FFF)
        #expect(try Self.down(0x0100, 16, 7) == 0)
    }

    @Test func equalWidthsAreTheIdentity() throws {
        for value: UInt32 in [0, 1, 63, 64, 65, 127] {
            #expect(try Self.up(value, 7, 7) == value)
            #expect(try Self.down(value, 7, 7) == value)
        }
        #expect(try Self.up(0xFFFF_FFFF, 32, 32) == 0xFFFF_FFFF)
        #expect(try Self.down(0xFFFF_FFFF, 32, 32) == 0xFFFF_FFFF)
    }

    @Test func sourceValueMustFitItsWidth() throws {
        #expect(try Self.up(127, 7, 16) == 0xFFFF)
        #expect(throws: UMPRefusal.valueOutOfRange(field: .scaledValue, value: 128)) { try Self.up(128, 7, 16) }
        #expect(try Self.down(0xFFFF, 16, 7) == 127)
        #expect(throws: UMPRefusal.valueOutOfRange(field: .scaledValue, value: 0x1_0000)) {
            try Self.down(0x1_0000, 16, 7)
        }
        #expect(throws: UMPRefusal.valueOutOfRange(field: .scaledValue, value: 2)) { try Self.up(2, 1, 8) }
        #expect(try Self.up(1, 1, 8) == 0xFF)
    }

    @Test func widthsAreChecked() throws {
        for (from, to) in [(0, 7), (8, 7), (7, 33), (-1, 7)] {
            #expect(throws: UMPRefusal.invalidScale(fromBits: from, toBits: to)) { try Self.up(0, from, to) }
        }
        for (from, to) in [(7, 0), (7, 8), (33, 7), (7, -1)] {
            #expect(throws: UMPRefusal.invalidScale(fromBits: from, toBits: to)) { try Self.down(0, from, to) }
        }
        #expect(try Self.up(1, 1, 32) == 0xFFFF_FFFF)
        #expect(try Self.down(0x8000_0000, 32, 1) == 1)
    }

    @Test func oneBitSourceMapsToMinimumAndMaximum() throws {
        // The documented exception to centre preservation: a 1-bit source's centre is its maximum.
        for to in [1, 7, 8, 14, 16, 32] {
            let maxOut = UInt32.max >> UInt32(32 - to)
            #expect(try Self.up(0, 1, to) == 0, "1→\(to) 0")
            #expect(try Self.up(1, 1, to) == maxOut, "1→\(to) 1")
        }
        #expect(try Self.up(1, 1, 7) == 0x7F)
        #expect(try Self.up(1, 1, 14) == 0x3FFF)
        #expect(try Self.up(1, 1, 16) == 0xFFFF)
    }

    @Test func oneBitRoundTripsAreTheIdentity() throws {
        for to in 1...32 {
            for value: UInt32 in [0, 1] {
                #expect(try Self.down(Self.up(value, 1, to), to, 1) == value, "1→\(to)→1 \(value)")
            }
            // Downscaling to 1 bit stays a right shift: the top bit decides.
            let centreOut = UInt32(1) << UInt32(to - 1)
            #expect(try Self.down(centreOut, to, 1) == 1)
            #expect(try Self.down(centreOut - 1, to, 1) == 0)
        }
    }

    @Test func onlyOneBitSourcesHaveMaximumEqualToCentre() throws {
        for from in 1...32 {
            let maxIn = UInt32.max >> UInt32(32 - from)
            let centre = UInt32(1) << UInt32(from - 1)
            #expect((maxIn == centre) == (from == 1), "from \(from)")
            for to in from...32 {
                let maxOut = UInt32.max >> UInt32(32 - to)
                let centreOut = UInt32(1) << UInt32(to - 1)
                #expect(try Self.up(0, from, to) == 0, "\(from)→\(to) min")
                #expect(try Self.up(maxIn, from, to) == maxOut, "\(from)→\(to) max")
                #expect(try Self.up(centre, from, to) == (from == 1 ? maxOut : centreOut), "\(from)→\(to) centre")
            }
        }
    }

    @Test func twoBitSourcesFollowTheNormalAlgorithm() throws {
        #expect(try Self.up(0, 2, 8) == 0)
        #expect(try Self.up(1, 2, 8) == 0x40)
        #expect(try Self.up(2, 2, 8) == 0x80)
        #expect(try Self.up(3, 2, 8) == 0xFF)
        #expect(try Self.up(1, 2, 7) == 0x20)
        #expect(try Self.up(2, 2, 7) == 0x40)
        #expect(try Self.up(3, 2, 7) == 0x7F)
        #expect(try Self.up(1, 2, 32) == 0x4000_0000)
        #expect(try Self.up(2, 2, 32) == 0x8000_0000)
        #expect(try Self.up(3, 2, 32) == 0xFFFF_FFFF)
        for value: UInt32 in 0...3 {
            #expect(try Self.down(Self.up(value, 2, 16), 16, 2) == value)
        }
    }
}
