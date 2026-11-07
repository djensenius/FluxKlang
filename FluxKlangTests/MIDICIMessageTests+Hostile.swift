//
//  MIDICIMessageTests+Hostile.swift
//  FluxKlangTests
//
//  Hostile input: huge and mutated payloads, fixed-seed pseudo-random bytes, the decode-then-encode identity and
//  the bounds-checked reader (#83, slice CI1). Nothing here uses a clock, the system random source or I/O.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    /// Fixed-seed xorshift: the same sequence on every machine.
    struct Xorshift {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// A successful decode must re-encode to exactly the input bytes (the encoding is canonical).
    static func reencodes(_ payload: [UInt8], limits: MIDICILimits = .standard) throws -> Bool? {
        guard let message = try? MIDICIMessage.decode(payload: payload, limits: limits) else { return nil }
        return try message.encode(limits: limits) == payload
    }

    @Test func aSixtyFiveThousandFiveHundredThirtySixByteInputIsRefusedAsTooLargeWhateverItsBytes() throws {
        let huge = [UInt8](repeating: 0x7E, count: 65_536)
        #expect(Self.decodeRefusal(huge) == .payloadTooLarge(65_536))
        let sevenBit = [UInt8](repeating: 0x00, count: 65_536)
        #expect(Self.decodeRefusal(sevenBit) == .payloadTooLarge(65_536))
    }

    @Test func everySingleByteChangeOfEveryGoldenEitherRefusesOrReencodesToTheChangedBytes() throws {
        var decoded = 0
        var refused = 0
        for golden in Self.goldens {
            for offset in golden.indices {
                for value in UInt8.min...UInt8.max {
                    let changed = Self.replacing(golden, at: offset, with: value)
                    switch try Self.reencodes(changed) {
                    case .some(let same):
                        #expect(same)
                        decoded += 1
                    case .none:
                        refused += 1
                    }
                }
            }
        }
        #expect(decoded > 0 && refused > decoded)
    }

    @Test func fixedSeedRandomPayloadsNeverTrapAndEverySuccessReencodesIdentically() throws {
        var random = Xorshift(seed: 0x4D49_4449_4349_0083)
        var successes = 0
        for round in 0..<6_000 {
            let length = Int(random.next() % 60)
            var payload = (0..<length).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            if round % 2 == 0 {
                payload = payload.map { $0 & 0x7F }
                if payload.count > 4 {
                    payload[0] = 0x7E
                    payload[2] = 0x0D
                    payload[3] = [0x70, 0x71, 0x7D, 0x7E, 0x7F][Int(random.next() % 5)]
                    payload[4] = UInt8(1 + random.next() % 2)
                }
            }
            if let same = try Self.reencodes(payload) {
                #expect(same)
                successes += 1
            }
        }
        #expect(successes > 0)
    }

    @Test func manyFieldValuesRoundTripThroughEncodeAndDecode() throws {
        let families: [UInt16] = [0, 1, 0x7F, 0x80, 0x3FFF]
        let sizes: [UInt32] = [0, 1, 0x7F, 0x80, 0x0FFF_FFFE, 0x0FFF_FFFF]
        for family in families {
            for size in sizes {
                let identity = try MIDICIDeviceIdentity.make(
                    manufacturer: [0x7F, 0, 1], family: family, model: 0x3FFF - family,
                    softwareRevision: [1, 0, 0, 0x7F])
                let info = try MIDICIDiscoveryInfo.make(
                    identity: identity, capabilityCategory: 0x7F, maximumSysExSize: size, outputPathID: 0x7F)
                let message = MIDICIMessage.discoveryReply(
                    try Self.header(.ci12, device: 0x7F), info, functionBlock: UInt8(family & 0x7F))
                let bytes = try message.encode(limits: .standard)
                #expect(try MIDICIMessage.decode(payload: bytes, limits: .standard) == message)
            }
        }
        for message in try Self.messages() {
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIMessage.decode(payload: bytes, limits: .standard) == message)
        }
        for length in [0, 1, 2, 127, 128, 129, 255, 256] {
            let message = try Self.ackMessage(text: String(repeating: "t", count: length))
            let bytes = try message.encode(limits: .standard)
            #expect(bytes.count == 23 + length)
            #expect(try MIDICIMessage.decode(payload: bytes, limits: .standard) == message)
        }
    }

    @Test func theReaderRefusesAReadPastTheEndWithoutConsumingAnything() throws {
        var reader = MIDICIReader([1, 2, 3], offset: 1)
        #expect(throws: MIDICIRefusal.truncated(need: 4, have: 3)) { try reader.take(3) }
        #expect(reader.offset == 1)
        #expect(throws: MIDICIRefusal.truncated(need: 0, have: 3)) { try reader.take(-1) }
        #expect(try reader.take(2) == [2, 3] && reader.offset == 3)
        #expect(try reader.take(0).isEmpty)
        #expect(throws: MIDICIRefusal.truncated(need: 4, have: 3)) { try reader.byte() }
        var beyond = MIDICIReader([1], offset: 5)
        #expect(throws: MIDICIRefusal.truncated(need: 5, have: 1)) { try beyond.take(0) }
    }

    @Test func wireCodingRoundTripsAndUsesSevenBitsLeastSignificantFirst() throws {
        #expect(MIDICIWire.encode(0x0FFF_FFFF, byteCount: 4) == Self.broadcastBytes)
        #expect(MIDICIWire.encode(300, byteCount: 2) == [0x2C, 0x02])
        #expect(MIDICIWire.decode([0x2C, 0x02]) == 300)
        for value: UInt32 in [0, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 0x0FFF_FFFF] {
            #expect(MIDICIWire.decode(MIDICIWire.encode(value, byteCount: 4)) == value)
        }
    }
}
