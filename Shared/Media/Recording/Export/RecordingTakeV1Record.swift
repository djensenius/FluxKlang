//
//  RecordingTakeV1Record.swift
//  FluxKlang
//
//  A cleared take as the media contract v1 `takeRecord` (#110 TKX1): exactly the schema's
//  fields, validated fail-closed and encoded deterministically. Pure: it writes no file and
//  assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `takeRecord` of a contract v1 trace (media-contract.md §8.3). Built only by `make`.
///
/// The take's types already guarantee the schema's other bounds, so they have no refusal here:
/// latency frames are non-negative and evidence is non-empty (`InputLatency`), there is at least one
/// segment and the segments are contiguous in the file (`RecordingTake`), and each segment's frames are
/// positive, its file start, offset and padding non-negative (`RecordingSegment`) and its generation
/// in range (`Generation`).
struct RecordingTakeV1Record: Hashable, Sendable {
    /// The `inputLatency` object. `measuredFrames` is written as `null` when nothing was measured.
    struct InputLatencyRecord: Hashable, Sendable {
        let reportedFrames: Int64
        let measuredFrames: Int64?
        let evidence: String?
    }

    /// One element of `segments`.
    struct Segment: Hashable, Sendable, Encodable {
        let sampleClock: ClockID
        let generation: Generation
        let startFrame: Int64
        let startOffsetNs: Int64
        let fileFrameStart: Int64
        let frames: Int64
        let paddedFrames: Int64
    }

    static let kind = "take"
    /// A bound of this exporter, not of the schema (which needs only a non-empty note): the evidence bound.
    static let maximumNoteBytes = MeasuredLatency.maximumEvidenceBytes

    let seq: Int
    let takeID: TakeID
    let stream: StreamID
    let inputLatency: InputLatencyRecord
    let segments: [Segment]
    let droppedFrames: Int64
    /// `user`, `diskFull` or `deviceLost`.
    let stopReason: String
    let note: String?

    /// Builds the record for `clearance`'s take at trace position `seq`, or throws the first refusal in the
    /// order `RecordingTakeV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(_ clearance: RecordingTakeV1Clearance, seq: Int,
                     note: String? = nil) throws(RecordingTakeV1RecordRefusal) -> RecordingTakeV1Record {
        let take = clearance.take
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(take.take.rawValue) else { throw .invalidTakeID(take.take) }
        guard MediaContractV1ID.matches(take.stream.rawValue) else { throw .invalidStream(take.stream) }
        let limit = TakeLedger.maximumSegmentsPerTake
        guard take.segments.count <= limit else { throw .tooManySegments(count: take.segments.count, limit: limit) }
        var segments: [Segment] = []
        segments.reserveCapacity(take.segments.count)
        for (index, segment) in take.segments.enumerated() {
            guard let offset = segment.startOffsetNs else { throw .uncleared(.unplacedSegment(index)) }
            guard MediaContractV1ID.matches(segment.clock.rawValue) else { throw .invalidSampleClock(segment: index) }
            segments.append(Segment(
                sampleClock: segment.clock, generation: segment.generation, startFrame: segment.startFrame,
                startOffsetNs: offset, fileFrameStart: segment.fileFrameStart, frames: segment.frames,
                paddedFrames: segment.paddedFrames))
        }
        let stopReason: String
        do {
            stopReason = try take.stopReason.contractV1StopReason()
        } catch {
            throw .uncleared(.stopReason(take.stopReason))
        }
        if let note {
            let bytes = note.utf8.count
            guard bytes <= maximumNoteBytes, note.contains(where: { !$0.isWhitespace }) else {
                throw .invalidNote(bytes: bytes)
            }
        }
        let latency = InputLatencyRecord(reportedFrames: take.inputLatency.reportedFrames,
                                         measuredFrames: take.inputLatency.measuredFrames,
                                         evidence: take.inputLatency.measured?.evidence)
        return RecordingTakeV1Record(seq: seq, takeID: take.take, stream: take.stream, inputLatency: latency,
                                     segments: segments, droppedFrames: take.droppedFrames,
                                     stopReason: stopReason, note: note)
    }

    private init(seq: Int, takeID: TakeID, stream: StreamID, inputLatency: InputLatencyRecord,
                 segments: [Segment], droppedFrames: Int64, stopReason: String, note: String?) {
        self.seq = seq
        self.takeID = takeID
        self.stream = stream
        self.inputLatency = inputLatency
        self.segments = segments
        self.droppedFrames = droppedFrames
        self.stopReason = stopReason
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; `note` and `evidence` are omitted when absent. Equal records encode to equal bytes.
    /// The output is bounded: at most `TakeLedger.maximumSegmentsPerTake` segments, IDs of at most
    /// `ContractID.maximumLength` (128) bytes, and a note and evidence of at most `maximumNoteBytes` each.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension RecordingTakeV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, stream, inputLatency, segments, droppedFrames, stopReason, note
        case takeID = "takeId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(takeID, forKey: .takeID)
        try container.encode(stream, forKey: .stream)
        try container.encode(inputLatency, forKey: .inputLatency)
        try container.encode(segments, forKey: .segments)
        try container.encode(droppedFrames, forKey: .droppedFrames)
        try container.encode(stopReason, forKey: .stopReason)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

extension RecordingTakeV1Record.InputLatencyRecord: Encodable {
    private enum CodingKeys: String, CodingKey {
        case reportedFrames, measuredFrames, evidence
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reportedFrames, forKey: .reportedFrames)
        if let measuredFrames {
            try container.encode(measuredFrames, forKey: .measuredFrames)
        } else {
            try container.encodeNil(forKey: .measuredFrames)
        }
        try container.encodeIfPresent(evidence, forKey: .evidence)
    }
}

/// The media contract v1 `$defs.id` pattern, `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`, matched byte by byte.
/// Stricter than `ContractID`, which also admits upper case, `_` and `:`.
enum MediaContractV1ID {
    static func matches(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard let first = bytes.first, isLower(first),
              let dot = bytes.firstIndex(of: UInt8(ascii: ".")), dot + 1 < bytes.count else { return false }
        let head = bytes[1..<dot].allSatisfy { isLower($0) || isDigit($0) || $0 == UInt8(ascii: "-") }
        let tail = bytes[(dot + 1)...].allSatisfy {
            isLower($0) || isDigit($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
        }
        return head && tail
    }

    private static func isLower(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
