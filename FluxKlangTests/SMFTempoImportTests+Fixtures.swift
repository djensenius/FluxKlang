import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Hand-built Standard MIDI File bytes and expected values for `SMFTempoImportTests`. Offsets used by the tests: the
/// header chunk is 14 bytes, so the first track body starts at byte 22 (its chunk header is 8 bytes).
extension SMFTempoImportTests {
    enum Fixture {
        static let endOfTrack: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]
        /// A Note On and Note Off pair of channel 1, middle C, one quarter long at division 480.
        static let note: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x83, 0x60, 0x80, 0x3C, 0x40]

        /// The variable-length quantity of `value` (at most 28 bits), written independently of the reader.
        static func vlq(_ value: UInt32) -> [UInt8] {
            var groups = [UInt8(value & 0x7F)]
            var rest = value >> 7
            while rest > 0 {
                groups.append(UInt8(rest & 0x7F) | 0x80)
                rest >>= 7
            }
            return groups.reversed()
        }

        static func word(_ value: Int) -> [UInt8] {
            [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }

        static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            Array(type.utf8) + word(body.count >> 16) + word(body.count & 0xFFFF) + body
        }

        static func header(format: Int = 1, tracks: Int, division: Int = 480, extra: [UInt8] = []) -> [UInt8] {
            chunk("MThd", word(format) + word(tracks) + word(division) + extra)
        }

        static func track(_ events: [UInt8], end: [UInt8] = endOfTrack) -> [UInt8] {
            chunk("MTrk", events + end)
        }

        /// A file whose header declares `tracks.count` tracks (or `declared`) and holds one MTrk chunk per entry.
        static func file(format: Int = 1, division: Int = 480, declared: Int? = nil,
                         tracks: [[UInt8]]) -> [UInt8] {
            header(format: format, tracks: declared ?? tracks.count, division: division)
                + tracks.flatMap { track($0) }
        }

        static func tempo(_ micros: Int, after delta: UInt32 = 0) -> [UInt8] {
            vlq(delta) + [0xFF, 0x51, 0x03, UInt8(micros >> 16 & 0xFF), UInt8(micros >> 8 & 0xFF), UInt8(micros & 0xFF)]
        }

        static func meter(_ numerator: Int, _ power: Int, clocks: UInt8 = 24, thirtySeconds: UInt8 = 8,
                          after delta: UInt32 = 0) -> [UInt8] {
            vlq(delta) + [0xFF, 0x58, 0x04, UInt8(numerator), UInt8(power), clocks, thirtySeconds]
        }

        static func meta(_ type: UInt8, _ payload: [UInt8], after delta: UInt32 = 0) -> [UInt8] {
            vlq(delta) + [0xFF, type] + vlq(UInt32(payload.count)) + payload
        }

        static func single(_ events: [UInt8], end: [UInt8] = endOfTrack) -> [UInt8] {
            header(tracks: 1) + track(events, end: end)
        }

        static func proposal(_ bytes: [UInt8], limits: SMFReadLimits = .standard) throws -> SMFTempoProposal {
            try SMFTempoScan.scan(bytes, limits: limits)
        }

        static func refusal(_ bytes: [UInt8], limits: SMFReadLimits = .standard) -> SMFTempoRefusal? {
            do {
                _ = try SMFTempoScan.scan(bytes, limits: limits)
                return nil
            } catch {
                return error
            }
        }

        static func readerRefusal(_ bytes: [UInt8], limits: SMFReadLimits = .standard) -> SMFRefusal? {
            do {
                _ = try StandardMIDIFile.read(bytes, limits: limits)
                return nil
            } catch {
                return error
            }
        }

        static func segment(_ ticks: Int64, _ micros: Int64) throws -> TempoSegment {
            try TempoSegment(atTicks: ticks, microsPerQuarter: micros)
        }

        static func segments(_ pairs: [[Int64]]) throws -> [TempoSegment] {
            try pairs.map { try segment($0[0], $0[1]) }
        }

        static func meterValue(_ numerator: Int, _ denominator: Int) throws -> MusicalMeter {
            try MusicalMeter(MeterFields(numerator: numerator, denominator: denominator))
        }

        static func change(_ ticks: Int64, _ numerator: Int, _ denominator: Int) throws -> SMFMeterChange {
            SMFMeterChange(atTicks: ticks, meter: try meterValue(numerator, denominator))
        }

        static let clock = ClockID(validated: "clock.musical.cl6")
    }
}
