//
//  GenerationV1Record.swift
//  FluxKlang
//
//  A generation bump as the media contract v1 `generationRecord` (#84 GXR1): exactly the schema's
//  fields, validated fail-closed and encoded deterministically. Pure: it writes no file, bumps no
//  counter and assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `generationRecord` of a contract v1 trace (media-contract.md §5). Built only by `make`.
///
/// The source types already guarantee the schema's other bounds, so they have no refusal here: `from` and `to`
/// are in 1…2^53 − 1 (`Generation`), the counter kind is one of the six schema kinds (`GenerationKind`), tempo
/// segments start at tick 0, strictly increase, number at most 4096 (`MusicalMap`) and have non-negative ticks
/// and tempos in 60 000…3 000 000 µs per quarter (`TempoSegmentFields`), and a meter's numerator is in 1…64 and
/// its denominator a power of two up to 32 (`MeterFields`).
///
/// Not checked here, because they need the trace's state: that `from` is the counter's current value, that the
/// counter is declared, and that a `musicalMap` revision changes the segments or the meter. The caller (the
/// `GenerationLedger` owner) holds that state.
struct GenerationV1Record: Hashable, Sendable {
    /// One element of `musicalMap`.
    struct TempoSegmentRecord: Hashable, Sendable, Encodable {
        let atTicks: Int64
        let microsPerQuarter: Int64
    }

    /// The `meter` object.
    struct MeterRecord: Hashable, Sendable, Encodable {
        let numerator: Int
        let denominator: Int
    }

    static let kind = "generation"
    /// The same bound as `RecordingTakeV1Record.maximumNoteBytes`; the schema needs only a non-empty note.
    static let maximumNoteBytes = RecordingTakeV1Record.maximumNoteBytes

    let seq: Int
    let counter: GenerationKey
    let from: Generation
    let to: Generation
    /// The `$defs.generationRecord.reason` name of the bump reason.
    let reason: String
    /// The whole new tempo map; present exactly for `musicalMap` counters.
    let musicalMap: [TempoSegmentRecord]?
    /// Present only for `rateChange`, the one reason that carries a rate. Other `sampleClock` reasons inherit it.
    let nominalRate: Int?
    /// Present only when the caller passes a meter with a `musicalMap` revision; absent means inherited (§5.6).
    let meter: MeterRecord?
    let note: String?

    /// Builds the record for bumping `counter` from `from` to `to` for `reason` at trace position `seq`, or throws
    /// the first refusal in the order `GenerationV1RecordRefusal` documents. Never clamps or remaps a value.
    ///
    /// A `musicalMap` counter needs the new map (`musicalMap`, whose clock is the counter's subject and whose
    /// revision is `to`) and may pass a `meter`; other counters pass neither. A `locate(ticks:)` reason writes
    /// `"locate"` only: the record has no tick field (the locate discontinuity and the next anchor carry the
    /// position), so the ticks are not written.
    static func make(counter: GenerationKey, from: Generation, to: Generation, reason: GenerationBumpReason,
                     musicalMap: MusicalMap? = nil, meter: MusicalMeter? = nil, seq: Int,
                     note: String? = nil) throws(GenerationV1RecordRefusal) -> GenerationV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(counter.subject.rawValue) else { throw .invalidCounterSubject(counter) }
        guard reason.kind == counter.kind else { throw .reasonDoesNotMatchKind(counter, reason) }
        guard let next = try? from.next(), next == to else { throw .notConsecutive(from: from, to: to) }
        var nominalRate: Int?
        if case .rateChange(let rate) = reason {
            guard MediaNominalRate.isValid(rate) else { throw .invalidRate(rate) }
            nominalRate = rate
        }
        let (segments, meterRecord) = try musicalPayload(counter: counter, to: to,
                                                         musicalMap: musicalMap, meter: meter)
        if let note {
            let bytes = note.utf8.count
            guard bytes <= maximumNoteBytes, note.contains(where: { !$0.isWhitespace }) else {
                throw .invalidNote(bytes: bytes)
            }
        }
        return GenerationV1Record(seq: seq, counter: counter, from: from, to: to, reason: reason.contractV1Name,
                                  musicalMap: segments, nominalRate: nominalRate, meter: meterRecord, note: note)
    }

    /// The `musicalMap` and `meter` fields: both for a `musicalMap` counter (the meter only when passed), neither
    /// otherwise.
    private static func musicalPayload(
        counter: GenerationKey, to: Generation, musicalMap: MusicalMap?, meter: MusicalMeter?
    ) throws(GenerationV1RecordRefusal) -> ([TempoSegmentRecord]?, MeterRecord?) {
        guard counter.kind == .musicalMap else {
            guard musicalMap == nil, meter == nil else { throw .musicalMapNotAllowed }
            return (nil, nil)
        }
        guard let musicalMap else { throw .musicalMapRequired }
        guard GenerationKey(.musicalMap, musicalMap.clock) == counter, musicalMap.revision == to else {
            throw .musicalMapMismatch
        }
        guard musicalMap.segments.allSatisfy(\.unknownFields.isEmpty), meter?.unknownFields.isEmpty ?? true else {
            throw .musicalMapExtensionFields
        }
        let segments = musicalMap.segments.map {
            TempoSegmentRecord(atTicks: $0.atTicks, microsPerQuarter: $0.microsPerQuarter)
        }
        return (segments, meter.map { MeterRecord(numerator: $0.numerator, denominator: $0.denominator) })
    }

    private init(seq: Int, counter: GenerationKey, from: Generation, to: Generation, reason: String,
                 musicalMap: [TempoSegmentRecord]?, nominalRate: Int?, meter: MeterRecord?, note: String?) {
        self.seq = seq
        self.counter = counter
        self.from = from
        self.to = to
        self.reason = reason
        self.musicalMap = musicalMap
        self.nominalRate = nominalRate
        self.meter = meter
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; every optional field is omitted when absent. `counter` is written `kind/subject`.
    /// Equal records encode to equal bytes. The output is bounded: a subject of at most
    /// `ContractID.maximumLength` (128) bytes, at most 4096 tempo segments and a note of at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension GenerationV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, counter, from, to, reason, musicalMap, nominalRate, meter, note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(counter.description, forKey: .counter)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(reason, forKey: .reason)
        try container.encodeIfPresent(musicalMap, forKey: .musicalMap)
        try container.encodeIfPresent(nominalRate, forKey: .nominalRate)
        try container.encodeIfPresent(meter, forKey: .meter)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

extension GenerationBumpReason {
    /// The `$defs.generationRecord.reason` name; associated values are not part of it.
    var contractV1Name: String {
        switch self {
        case .deviceRestart: "deviceRestart"
        case .rateChange: "rateChange"
        case .configurationChange: "configurationChange"
        case .wake: "wake"
        case .locate: "locate"
        case .clockRestart: "clockRestart"
        case .transportRestart: "transportRestart"
        case .tempoEdit: "tempoEdit"
        case .externalTempo: "externalTempo"
        case .sourceLost: "sourceLost"
        case .sourceReacquired: "sourceReacquired"
        case .contextChange: "contextChange"
        case .userCancel: "userCancel"
        }
    }
}
