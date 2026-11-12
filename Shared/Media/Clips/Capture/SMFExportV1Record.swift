//
//  SMFExportV1Record.swift
//  FluxKlang
//
//  A written Standard MIDI File as the media contract v1 `exportRecord` (#548 SMF3): exactly the schema's
//  fields for `format: smf`, validated fail-closed and encoded deterministically. Pure: it
//  writes no file and assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `smf` `exportRecord` of a contract v1 trace (media-contract.md §9.3). Built only by `make`.
///
/// It describes the bytes it is given: `smfFormat` and `division` are read from their `MThd` header, never assumed,
/// and `losses` are the file's declared losses, only counts of at least 1. `lossless` is computed, true exactly when
/// `losses` is empty, as the checker requires. It never writes the native-UMP-only `origin` and `offsetsNs`, and it
/// does not hold the bytes or examine the header's track count. The streams and the export ID come from the caller
/// and cannot be checked against the file. The export's pairing repairs (`unpairedOffs`, `openNotesClosed`,
/// `widenedNotes`, `retriggeredNotes`) are not §9.3 losses and are not part of the record.
struct SMFExportV1Record: Hashable, Sendable {
    static let kind = "export"
    static let format = "smf"
    /// A bound of this exporter, not of the schema (which needs only a non-empty note): the TKX1 note bound.
    static let maximumNoteBytes = MediaContractV1Note.maximumBytes

    let seq: Int
    let exportID: ExportID
    /// The export's streams in caller order, unchanged as in the golden examples; the schema requires no sorting.
    let streams: [StreamID]
    /// The header's format, 0 or 1.
    let smfFormat: UInt16
    /// The header's ticks per quarter note, a divisor of `MusicalTime.ticksPerQuarter`.
    let division: UInt16
    /// Only categories with a count of at least 1.
    let losses: [SMFExportLoss: Int]
    let note: String?

    /// True exactly when `losses` is empty.
    var lossless: Bool { losses.isEmpty }

    /// Builds the record for `file` at trace position `seq`, or throws the first refusal in the order
    /// `SMFExportV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(_ file: SMFWriteResult, streams: [StreamID], exportID: ExportID, seq: Int,
                     note: String? = nil) throws(SMFExportV1RecordRefusal) -> SMFExportV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(exportID.rawValue) else { throw .invalidExportID(exportID) }
        guard !streams.isEmpty else { throw .noStreams }
        guard streams.count <= MIDICaptureLog.maximumStreams else { throw .tooManyStreams(count: streams.count) }
        var seen = Set<StreamID>()
        for stream in streams where !seen.insert(stream).inserted { throw .duplicateStream(stream) }
        if let stream = streams.first(where: { !MediaContractV1ID.matches($0.rawValue) }) {
            throw .invalidStream(stream)
        }
        let (smfFormat, division) = try header(file.bytes)
        for loss in SMFExportLoss.allCases {
            if let count = file.losses.losses[loss], count < 1 { throw .invalidLossCount(loss: loss, count: count) }
        }
        if let note, !MediaContractV1Note.isValid(note) { throw .invalidNote(bytes: note.utf8.count) }
        return SMFExportV1Record(seq: seq, exportID: exportID, streams: streams, smfFormat: smfFormat,
                                 division: division, losses: file.losses.losses, note: note)
    }

    /// The format and division of the `MThd` chunk at the start of `bytes`, checked as `StandardMIDIFileReader` does.
    /// The track count (bytes 10 and 11) is not examined.
    private static func header(_ bytes: [UInt8]) throws(SMFExportV1RecordRefusal)
        -> (format: UInt16, division: UInt16) {
        guard bytes.count >= 14, bytes.prefix(4).elementsEqual("MThd".utf8) else { throw .unreadableHeader }
        let length = bytes[4...7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length >= 6, length <= UInt64(bytes.count - 8) else { throw .unreadableHeader }
        let format = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        let division = UInt16(bytes[12]) << 8 | UInt16(bytes[13])
        guard format <= 1 else { throw .unsupportedFormat(format) }
        guard division & 0x8000 == 0 else { throw .smpteDivision(division) }
        guard division > 0, MusicalTime.ticksPerQuarter % Int64(division) == 0 else {
            throw .unsupportedDivision(division)
        }
        return (format, division)
    }

    private init(seq: Int, exportID: ExportID, streams: [StreamID], smfFormat: UInt16, division: UInt16,
                 losses: [SMFExportLoss: Int], note: String?) {
        self.seq = seq
        self.exportID = exportID
        self.streams = streams
        self.smfFormat = smfFormat
        self.division = division
        self.losses = losses
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields for `smf`; `note` is omitted when absent. Records built from the same inputs, with
    /// byte-identical `note` text, encode to identical bytes. Swift `String` equality is canonical, so records
    /// whose notes differ only in Unicode normalization compare equal but encode differently; text is never
    /// normalized.
    /// The output is bounded: at most `MIDICaptureLog.maximumStreams` streams, IDs of at most
    /// `ContractID.maximumLength` (128) bytes, eleven losses and a note of at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension SMFExportV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, streams, format, smfFormat, division, lossless, losses, note
        case exportID = "exportId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(exportID, forKey: .exportID)
        try container.encode(streams, forKey: .streams)
        try container.encode(Self.format, forKey: .format)
        try container.encode(smfFormat, forKey: .smfFormat)
        try container.encode(division, forKey: .division)
        try container.encode(lossless, forKey: .lossless)
        // A dictionary keyed by an enum encodes as an alternating array, so the schema's object is keyed by raw value.
        try container.encode(Dictionary(uniqueKeysWithValues: losses.map { ($0.key.rawValue, $0.value) }),
                             forKey: .losses)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
