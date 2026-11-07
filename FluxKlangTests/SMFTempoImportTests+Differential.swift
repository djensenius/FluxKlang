import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The scan and the shipped reader must agree on every structural refusal of the same bytes.
extension SMFTempoImportTests {
    private static let rich: [UInt8] = F.file(tracks: [
        F.tempo(600_000) + F.meter(3, 2) + [0x00, 0x90, 0x3C, 0x64, 0x60, 0x80, 0x3C, 0x40, 0x10, 0x3E, 0x40]
            + F.meta(0x01, [0x41]) + [0x00, 0xF0, 0x02, 0x01, 0xF7] + F.tempo(700_000, after: 96),
        F.meter(5, 3, after: 10) + [0x00, 0xB0, 0x07, 0x64] + [0x00, 0xC0, 0x05]
    ])

    /// Reader refusals that come from note pairing or clip building, which the scan does not perform.
    private static func isSemantic(_ refusal: SMFRefusal) -> Bool {
        switch refusal {
        case .noteOnWhileSounding, .noteNotReleased, .clip: true
        default: false
        }
    }

    /// How the scan and the reader fared on each variant. A scan tempo or meter refusal is `agreed` when the reader
    /// accepts the bytes or refuses only for a non-replicated reason, and `ahead` when the reader reports a
    /// structural defect that lies after the scan's refusal (the reader reads tempo and meter events as opaque).
    /// Limit: `ahead` accepts any structural reader refusal; it is not checked to lie after the scan's refusal point.
    private struct Tally: Equatable {
        var variants = 0
        var matched = 0
        var accepted = 0
        var agreed = 0
        var ahead = 0
    }

    private func compare(_ bytes: [UInt8], tally: inout Tally, label: String) {
        let reader = F.readerRefusal(bytes)
        let semanticOrNone = reader.map(Self.isSemantic) ?? true
        tally.variants += 1
        switch F.refusal(bytes) {
        case nil:
            tally.accepted += 1
            #expect(semanticOrNone, "scan accepted \(label); reader refused \(String(describing: reader))")
        case .file(let refusal)?:
            tally.matched += 1
            #expect(refusal == reader, "\(label)")
        case .some:
            if semanticOrNone { tally.agreed += 1 } else { tally.ahead += 1 }
        }
    }

    @Test func everyPrefixOfARichFileIsRefusedExactlyAsTheReaderRefusesIt() {
        var tally = Tally()
        for length in 0...Self.rich.count {
            compare(Array(Self.rich.prefix(length)), tally: &tally, label: "prefix \(length)")
        }
        // Pinned: one variant per prefix length (97 bytes); 96 refused alike, only the whole file accepted.
        #expect(tally == Tally(variants: Self.rich.count + 1, matched: 96, accepted: 1, agreed: 0, ahead: 0))
    }

    @Test func everySingleByteSubstitutionIsRefusedExactlyAsTheReaderRefusesIt() {
        var tally = Tally()
        let values: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xF0, 0xFF]
        for index in Self.rich.indices {
            for value in values where Self.rich[index] != value {
                var bytes = Self.rich
                bytes[index] = value
                compare(bytes, tally: &tally, label: "byte \(index)=\(value)")
            }
        }
        let same = Self.rich.reduce(0) { $0 + (values.contains($1) ? 1 : 0) }
        // Pinned: six values at every offset, minus the substitutions that change nothing. A change in any of the
        // four counts means the scan or the reader moved, or the rich file did.
        #expect(tally == Tally(variants: Self.rich.count * 6 - same, matched: 323, accepted: 178, agreed: 30,
                               ahead: 9))
    }

    @Test func everyResealedTrackBodyCutIsRefusedExactlyAsTheReaderRefusesIt() {
        let body = F.tempo(600_000) + F.meter(3, 2) + [0x00, 0x90, 0x3C, 0x64, 0x60, 0x80, 0x3C, 0x40]
            + F.meta(0x01, [0x41, 0x42]) + [0x00, 0xF0, 0x02, 0x01, 0xF7]
        var tally = Tally()
        for end in [[UInt8](), F.endOfTrack] {
            for length in 0...body.count {
                let bytes = F.header(tracks: 1) + F.track(Array(body.prefix(length)), end: end)
                compare(bytes, tally: &tally, label: "cut \(length) end \(end.count)")
            }
        }
        // Pinned: every cut of the body, with and without an End of Track: 70 variants.
        #expect(tally == Tally(variants: 2 * (body.count + 1), matched: 60, accepted: 7, agreed: 0, ahead: 3))
    }

    @Test func appendingTrailingBytesOrAnExtraTrackIsRefusedExactlyAsTheReaderRefusesIt() {
        var tally = Tally()
        for tail in [[UInt8](), [0x00], [0x4D, 0x54, 0x72, 0x6B], [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 9]] {
            compare(Self.rich + tail, tally: &tally, label: "tail \(tail.count)")
        }
        compare(Self.rich + F.track(F.tempo(5)), tally: &tally, label: "extra track")
        #expect(tally == Tally(variants: 5, matched: 4, accepted: 1, agreed: 0, ahead: 0))
    }
}
