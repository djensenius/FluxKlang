import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - Nibble join validation (Copilot r1)

private func pieceRefusal(_ piece: UInt8, _ nibble: UInt8) -> TimecodeError? {
    do { _ = try MTCQuarterFrame(piece: piece, nibble: nibble) } catch { return error }
    return nil
}

private func joinOutcome(_ nibbles: [UInt8]) -> Result<SMPTETime, TimecodeError> {
    do { return .success(try MTCQuarterFrame.time(fromNibbles: nibbles)) } catch { return .failure(error) }
}

extension MIDITimecodeTests {
    @Test func joinRefusesCopilotReportedInputs() {
        #expect(throws: TimecodeError.reservedBitsSet(piece: 7, nibble: 8)) {
            try MTCQuarterFrame.time(fromNibbles: [0, 0, 0, 0, 0, 0, 0, 8])
        }
        #expect(throws: TimecodeError.invalidPiece(piece: 0, nibble: 16)) {
            try MTCQuarterFrame.time(fromNibbles: [16, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    @Test func nibbleFifteenAcceptedSixteenRefusedPerPiece() throws {
        for piece in UInt8(0)...7 {
            var nibbles = [UInt8](repeating: 0, count: 8)
            nibbles[Int(piece)] = 16
            #expect(throws: TimecodeError.invalidPiece(piece: piece, nibble: 16)) {
                try MTCQuarterFrame(piece: piece, nibble: 16)
            }
            #expect(throws: TimecodeError.invalidPiece(piece: piece, nibble: 16)) {
                try MTCQuarterFrame.time(fromNibbles: nibbles)
            }
            guard piece.isMultiple(of: 2) else { continue }
            nibbles[Int(piece)] = 15
            #expect(try MTCQuarterFrame(piece: piece, nibble: 15).nibble == 15)
            let joined = try MTCQuarterFrame.time(fromNibbles: nibbles)
            #expect(MTCQuarterFrame.pieces(for: joined).map(\.nibble) == nibbles)
        }
    }

    @Test func pieceSevenReservedBitRefusedAtEveryRateCode() throws {
        for code in UInt8(0)...3 {
            for hourBit: UInt8 in [0, 1] {
                let legal = code << 1 | hourBit
                let nibbles: [UInt8] = [0, 0, 0, 0, 0, 0, 0, legal]
                #expect(try MTCQuarterFrame.time(fromNibbles: nibbles).rate == SMPTEFrameRate(code: code))
                let reserved = legal | 0x8
                #expect(throws: TimecodeError.reservedBitsSet(piece: 7, nibble: reserved)) {
                    try MTCQuarterFrame.time(fromNibbles: [0, 0, 0, 0, 0, 0, 0, reserved])
                }
            }
        }
    }

    /// Every single-element corruption of a valid sequence: the join refuses exactly what the piece path
    /// refuses, with the same error, and otherwise never loses bits.
    @Test func joinMatchesPiecePathForEverySingleElementCorruption() throws {
        let base = MTCQuarterFrame.pieces(for: try smpte(10, 20, 30, 12, .fps25)).map(\.nibble)
        var refused = 0
        var mismatches: [String] = []
        for piece in UInt8(0)...7 {
            for value in UInt8.min...UInt8.max {
                var nibbles = base
                nibbles[Int(piece)] = value
                let outcome = joinOutcome(nibbles)
                if let expected = pieceRefusal(piece, value) {
                    refused += 1
                    if outcome != .failure(expected) { mismatches.append("\(piece)/\(value)") }
                    continue
                }
                switch outcome {
                case let .success(time) where MTCQuarterFrame.pieces(for: time).map(\.nibble) == nibbles: break
                case .success, .failure(.invalidPiece), .failure(.reservedBitsSet):
                    mismatches.append("\(piece)/\(value)")
                case .failure: break
                }
            }
        }
        #expect(mismatches.isEmpty)
        // Per piece, 256 minus the legal values: 4 × 240 + 254 + 252 + 252 + 248.
        #expect(refused == 1966)
    }
}
