//
//  ClocksV1Record.swift
//  FluxKlang
//
//  A transport document and the host timebase as the media contract v1 trace header's `clocks` object (#84 CXR1,
//  media-contract.md §2, §5.2, §5.5, §5.6): exactly the schema's fields, validated fail-closed and encoded
//  deterministically. Pure: it writes no file and reads no clock; the caller passes the host timebase.
//

import Foundation

/// The `clocks` object of a contract v1 trace header (`$defs.clocks`). Built only by `make`.
///
/// `sample[0]` is the transport's primary clock, which the checker treats as the primary; extra sample clocks
/// follow in the order given. The header has no `initialGenerations`: that is a separate top-level trace field.
///
/// The source types already guarantee the schema's other bounds, so they have no refusal here: the primary rate is
/// in the v1 rate set and the musical clock differs from the primary, has a meter and a map (`TransportFields`);
/// tempo segments start at tick 0, strictly increase and number 1…4096 (`MusicalMap`) with non-negative `Int64`
/// ticks and tempos in 60 000…3 000 000 µs per quarter (`TempoSegmentFields`); a meter's numerator is in 1…64 and
/// its denominator a power of two up to 32 (`MeterFields`); and a loop has `0 ≤ startTicks < endTicks`
/// (`LoopRange`), so `endTicks ≥ 1`. Every tick is an `Int64`, inside the checker's `[0, 2^63)` tick range.
///
/// Ticks are written unconverted: the transport types count `MusicalTime.ticksPerQuarter` (15 360) ticks per
/// quarter, the schema's `ticksPerQuarter` constant, so the conversion is the identity and never inexact.
struct ClocksV1Record: Hashable, Sendable {
    /// One element of `sample`; also the input type of an extra sample clock.
    struct SampleClock: Hashable, Sendable {
        let clockID: ClockID
        let nominalRate: Int
    }

    /// The optional `musical.loop` object.
    struct LoopRecord: Hashable, Sendable, Encodable {
        let startTicks: Int64
        let endTicks: Int64
    }

    typealias TempoSegmentRecord = GenerationV1Record.TempoSegmentRecord
    typealias MeterRecord = GenerationV1Record.MeterRecord

    /// The schema's `musical.ticksPerQuarter` constant; equal to `MusicalTime.ticksPerQuarter`.
    static let ticksPerQuarter: Int64 = 15_360

    let timebase: HostTimebase
    /// The primary clock first, then the extra sample clocks in the order given.
    let sample: [SampleClock]
    let musicalClock: ClockID
    let meter: MeterRecord
    /// The transport's tempo segments, in order.
    let musicalMap: [TempoSegmentRecord]
    /// Present exactly when the transport has an active loop.
    let loop: LoopRecord?

    /// Builds the `clocks` object for `transport` on a host whose nanoseconds per tick are
    /// `timebase.numer / timebase.denom`, with `extraSampleClocks` after the transport's primary clock, or throws
    /// the first refusal in the order `ClocksV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(transport: TransportDocument, timebase: HostTimebase,
                     extraSampleClocks: [SampleClock] = []) throws(ClocksV1RecordRefusal) -> ClocksV1Record {
        let fields = transport.payload.fields
        // `TransportFields` guarantees a meter whenever there is a musical clock.
        guard let musicalClock = fields.musicalClock, let meter = fields.meter else { throw .missingMusicalClock }
        guard timebase.numer > 0, timebase.denom > 0 else {
            throw .invalidTimebase(numer: timebase.numer, denom: timebase.denom)
        }
        let sample = [SampleClock(clockID: fields.primaryClock, nominalRate: fields.nominalRate)] + extraSampleClocks
        let clocks = sample.map(\.clockID) + [musicalClock]
        if let invalid = clocks.first(where: { !MediaContractV1ID.matches($0.rawValue) }) {
            throw .invalidClockID(invalid)
        }
        if let invalid = extraSampleClocks.first(where: { !MediaNominalRate.isValid($0.nominalRate) }) {
            throw .invalidRate(clock: invalid.clockID, rate: invalid.nominalRate)
        }
        var seen = Set<ClockID>()
        if let repeated = clocks.first(where: { !seen.insert($0).inserted }) { throw .duplicateClockID(repeated) }
        guard fields.segments.allSatisfy(\.unknownFields.isEmpty), meter.unknownFields.isEmpty,
              fields.loop?.unknownFields.isEmpty ?? true else { throw .extensionFields }
        return ClocksV1Record(
            timebase: timebase, sample: sample, musicalClock: musicalClock,
            meter: MeterRecord(numerator: meter.numerator, denominator: meter.denominator),
            musicalMap: fields.segments.map {
                TempoSegmentRecord(atTicks: $0.atTicks, microsPerQuarter: $0.microsPerQuarter)
            },
            loop: fields.loop.map { LoopRecord(startTicks: $0.startTicks, endTicks: $0.endTicks) }
        )
    }

    private init(timebase: HostTimebase, sample: [SampleClock], musicalClock: ClockID, meter: MeterRecord,
                 musicalMap: [TempoSegmentRecord], loop: LoopRecord?) {
        self.timebase = timebase
        self.sample = sample
        self.musicalClock = musicalClock
        self.meter = meter
        self.musicalMap = musicalMap
        self.loop = loop
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; `musical.loop` is omitted when absent and `musical.ticksPerQuarter` is always 15360.
    /// Records built from the same inputs encode to identical bytes; the record holds no free text.
    /// The output is bounded by the inputs: IDs of at most `ContractID.maximumLength` (128) bytes, at most 4096
    /// tempo segments, and the caller's extra sample clocks.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension ClocksV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case host, sample, musical
    }

    private enum HostKeys: String, CodingKey {
        case timebaseNumer, timebaseDenom
    }

    private enum MusicalKeys: String, CodingKey {
        case ticksPerQuarter, meter, musicalMap, loop
        case clockID = "clockId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var host = container.nestedContainer(keyedBy: HostKeys.self, forKey: .host)
        try host.encode(timebase.numer, forKey: .timebaseNumer)
        try host.encode(timebase.denom, forKey: .timebaseDenom)
        try container.encode(sample, forKey: .sample)
        var musical = container.nestedContainer(keyedBy: MusicalKeys.self, forKey: .musical)
        try musical.encode(musicalClock, forKey: .clockID)
        try musical.encode(Self.ticksPerQuarter, forKey: .ticksPerQuarter)
        try musical.encode(meter, forKey: .meter)
        try musical.encode(musicalMap, forKey: .musicalMap)
        try musical.encodeIfPresent(loop, forKey: .loop)
    }
}

extension ClocksV1Record.SampleClock: Encodable {
    private enum CodingKeys: String, CodingKey {
        case nominalRate
        case clockID = "clockId"
    }
}
