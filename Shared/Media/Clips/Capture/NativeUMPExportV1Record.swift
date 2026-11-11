//
//  NativeUMPExportV1Record.swift
//  FluxKlang
//
//  A native UMP export as the media contract v1 `exportRecord` (#112 NXR1): exactly the schema's
//  fields for `format: nativeUmp`, validated fail-closed and encoded deterministically. Pure: it
//  writes no file and assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `nativeUmp` `exportRecord` of a contract v1 trace (media-contract.md §9.2). Built only by `make`.
///
/// It never writes the SMF-only `smfFormat` and `division`, and it is always lossless with no losses, as the
/// checker requires (`lossless` is true exactly when `losses` is empty). The export's types already guarantee the
/// schema's other bounds, so they have no refusal here: at least one distinct stream (`NativeUMPExport`), and an origin
/// generation in range (`Generation`). The packets are not part of the record.
struct NativeUMPExportV1Record: Hashable, Sendable {
    /// The `origin` object: the take start as clock, generation and frame.
    struct Origin: Hashable, Sendable, Encodable {
        let sampleClock: ClockID
        let generation: Generation
        let frame: Int64
    }

    static let kind = "export"
    static let format = "nativeUmp"
    /// A bound of this exporter, not of the schema (which needs only a non-empty note): the TKX1 note bound.
    static let maximumNoteBytes = RecordingTakeV1Record.maximumNoteBytes

    let seq: Int
    let exportID: ExportID
    /// The export's streams in caller order, unchanged as in the golden examples; the schema requires no sorting.
    let streams: [StreamID]
    let origin: Origin
    let offsetsNs: [Int64]
    let note: String?

    /// Always true: a native UMP export that cannot be lossless is refused before it exists.
    var lossless: Bool { true }
    /// Always empty, matching `lossless`.
    var losses: [String: Int] { [:] }

    /// Builds the record for `export` at trace position `seq`, or throws the first refusal in the order
    /// `NativeUMPExportV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(_ export: NativeUMPExport, seq: Int,
                     note: String? = nil) throws(NativeUMPExportV1RecordRefusal) -> NativeUMPExportV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(export.id.rawValue) else { throw .invalidExportID(export.id) }
        if let stream = export.streams.first(where: { !MediaContractV1ID.matches($0.rawValue) }) {
            throw .invalidStream(stream)
        }
        guard MediaContractV1ID.matches(export.origin.clock.rawValue) else {
            throw .invalidOriginClock(export.origin.clock)
        }
        if let index = export.offsetsNs.firstIndex(where: { $0 < 0 }) {
            throw .negativeOffset(index: index, offsetNs: export.offsetsNs[index])
        }
        if let note {
            let bytes = note.utf8.count
            guard bytes <= maximumNoteBytes, note.contains(where: { !$0.isWhitespace }) else {
                throw .invalidNote(bytes: bytes)
            }
        }
        let origin = Origin(sampleClock: export.origin.clock, generation: export.origin.generation,
                            frame: export.origin.frame)
        return NativeUMPExportV1Record(seq: seq, exportID: export.id, streams: export.streams, origin: origin,
                                       offsetsNs: export.offsetsNs, note: note)
    }

    private init(seq: Int, exportID: ExportID, streams: [StreamID], origin: Origin, offsetsNs: [Int64],
                 note: String?) {
        self.seq = seq
        self.exportID = exportID
        self.streams = streams
        self.origin = origin
        self.offsetsNs = offsetsNs
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields for `nativeUmp`; `note` is omitted when absent. Equal records encode to equal bytes.
    /// The output is bounded: at most `MIDICaptureLog.maximumStreams` streams and `MIDICaptureLog.maximumCaptures`
    /// offsets, IDs of at most `ContractID.maximumLength` (128) bytes, and a note of at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension NativeUMPExportV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, streams, format, lossless, losses, origin, offsetsNs, note
        case exportID = "exportId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(exportID, forKey: .exportID)
        try container.encode(streams, forKey: .streams)
        try container.encode(Self.format, forKey: .format)
        try container.encode(origin, forKey: .origin)
        try container.encode(offsetsNs, forKey: .offsetsNs)
        try container.encode(lossless, forKey: .lossless)
        try container.encode(losses, forKey: .losses)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
