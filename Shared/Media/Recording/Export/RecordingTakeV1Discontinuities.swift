//
//  RecordingTakeV1Discontinuities.swift
//  FluxKlang
//
//  A cleared take's own media contract v1 `discontinuityRecord`s (#110 TKX2): one `overflow` per
//  padded interval and the `captureStopped` of a non-`user` stop, validated fail-closed and encoded
//  deterministically. Pure: it writes no file and numbers nothing itself; the caller passes the seqs.
//

import Foundation

/// Why a cleared take's discontinuities cannot become contract v1 records. In memory only; nothing is
/// clamped, remapped or serialized in its place. `RecordingTakeV1Discontinuities.make` throws the first
/// offence in this order: the seqs (their count, then by lowest index a seq below 1 or not above the one
/// before), the stream, the segment count, then per segment (lowest index first) its `sampleClock` and its
/// overflows' frame counts, then the notes in ascending seq order. Seqs, stream, segment count and clock
/// follow `RecordingTakeV1RecordRefusal`'s relative order, so a take whose `takeRecord` is refused for one of
/// them yields no discontinuity record either.
enum RecordingTakeV1DiscontinuityRefusal: Error, Hashable, Sendable {
    /// `seqs` does not hold exactly one seq per record (`RecordingTakeV1Discontinuities.count(of:)`).
    case seqCount(expected: Int, actual: Int)
    /// The seq at this index of `seqs` is below 1.
    case invalidSeq(index: Int, seq: Int)
    /// The seq at this index of `seqs` is not above the one before it.
    case seqNotIncreasing(index: Int, seq: Int)
    /// The stream ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidStream(StreamID)
    /// The take has more segments than `TakeLedger.maximumSegmentsPerTake` (`limit`), as
    /// `RecordingTakeV1RecordRefusal.tooManySegments`. Only a hand-built take reaches this.
    case tooManySegments(count: Int, limit: Int)
    /// The segment at this index names a sample clock that does not match the media contract ID pattern.
    /// The gate clears only takes whose segments share one clock, so through a clearance this is always
    /// segment 0.
    case invalidSampleClock(segment: Int)
    /// An overflow of this segment pads more frames than the schema's `frames` maximum
    /// (`RecordingTakeV1DiscontinuityRecord.maximumFrames`). The ledger reads overflow counts as `UInt32`,
    /// so only a hand-built segment reaches this.
    case overflowFramesOutOfRange(segment: Int, frames: Int64)
    /// The note for this seq is empty, all whitespace, or longer than `RecordingTakeV1Record.maximumNoteBytes`
    /// UTF-8 bytes.
    case invalidNote(seq: Int, bytes: Int)
    /// A note is keyed by a seq that numbers none of the records.
    case noteWithoutRecord(seq: Int)
}

/// One contract v1 `discontinuityRecord` a take owns (media-contract.md §8.3-8.4). Built only by
/// `RecordingTakeV1Discontinuities.make`.
///
/// The take's types already guarantee the schema's other bounds, so they have no refusal here: `frame`
/// is an `Int64`, `generation` is in range (`Generation`), an overflow pads at least one frame and lies
/// wholly inside its segment (`OverflowInterval`, `RecordingSegment`), and a stop mark sits at the end
/// of the last segment with the take's stop reason (`RecordingTake`).
struct RecordingTakeV1DiscontinuityRecord: Hashable, Sendable {
    /// The two discontinuity types a take owns.
    enum DiscontinuityType: String, Hashable, Sendable, Encodable {
        case overflow, captureStopped
    }

    static let kind = "discontinuity"
    /// The schema's `frames` maximum, 2^32 − 1.
    static let maximumFrames: Int64 = 4_294_967_295

    let seq: Int
    let type: DiscontinuityType
    let sampleClock: ClockID
    let generation: Generation
    /// An overflow's first padded frame, or the stop's frame (the end of the last segment).
    let frame: Int64
    /// The padded frame count of an `overflow`; nil for `captureStopped`.
    let frames: Int64?
    let stream: StreamID
    /// `diskFull` or `deviceLost` for `captureStopped`; nil for `overflow`.
    let reason: String?
    let note: String?

    fileprivate init(seq: Int, type: DiscontinuityType, sampleClock: ClockID, generation: Generation, frame: Int64,
                     frames: Int64?, stream: StreamID, reason: String?, note: String?) {
        self.seq = seq
        self.type = type
        self.sampleClock = sampleClock
        self.generation = generation
        self.frame = frame
        self.frames = frames
        self.stream = stream
        self.reason = reason
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; `frames`, `reason` and `note` are omitted when absent. Records built from the same
    /// inputs, with byte-identical `note` text, encode to identical bytes. Swift `String` equality is canonical,
    /// so records whose notes differ only in Unicode normalization compare equal but encode differently; text is
    /// never normalized.
    /// The output is bounded: IDs of at most `ContractID.maximumLength` (128) bytes and a note of at most
    /// `RecordingTakeV1Record.maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension RecordingTakeV1DiscontinuityRecord: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, type, sampleClock, generation, frame, frames, stream, reason, note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(type, forKey: .type)
        try container.encode(sampleClock, forKey: .sampleClock)
        try container.encode(generation, forKey: .generation)
        try container.encode(frame, forKey: .frame)
        try container.encodeIfPresent(frames, forKey: .frames)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

/// Builds a cleared take's own discontinuity records. Their order is fixed: every segment in order, each
/// one's overflows in ascending frame order, then the `captureStopped` (none for a `user` stop). A trace
/// interleaves them with other records, so they are not numbered consecutively: the caller asks
/// `count(of:)`, picks that many strictly increasing seqs, and passes them to `make` in that order.
enum RecordingTakeV1Discontinuities {
    /// How many records `make` builds for `clearance`, and so how many seqs it needs.
    static func count(of clearance: RecordingTakeV1Clearance) -> Int {
        let take = clearance.take
        return take.segments.reduce(0) { $0 + $1.overflows.count } + (take.captureStopped == nil ? 0 : 1)
    }

    /// The records for `clearance`'s take, `seqs[i]` numbering the i-th, with `notes[seq]` as the note of
    /// the record numbered `seq`. Throws the first refusal in the order `RecordingTakeV1DiscontinuityRefusal`
    /// documents. Never clamps or remaps a value.
    static func make(_ clearance: RecordingTakeV1Clearance, seqs: [Int], notes: [Int: String] = [:])
        throws(RecordingTakeV1DiscontinuityRefusal) -> [RecordingTakeV1DiscontinuityRecord] {
        let take = clearance.take
        let expected = count(of: clearance)
        try validate(seqs: seqs, expected: expected)
        try validate(take)
        try validate(notes: notes, seqs: seqs)
        var records: [RecordingTakeV1DiscontinuityRecord] = []
        records.reserveCapacity(expected)
        for segment in take.segments {
            for interval in segment.overflows {
                let seq = seqs[records.count]
                records.append(RecordingTakeV1DiscontinuityRecord(
                    seq: seq, type: .overflow, sampleClock: segment.clock, generation: segment.generation,
                    frame: interval.startFrame, frames: interval.frames, stream: take.stream, reason: nil,
                    note: notes[seq]))
            }
        }
        // `captureStopped` holds only a mark whose stop has a capture reason, and a take is never empty.
        if let mark = take.captureStopped, let reason = mark.reason.captureReason, let last = take.segments.last {
            let seq = seqs[records.count]
            records.append(RecordingTakeV1DiscontinuityRecord(
                seq: seq, type: .captureStopped, sampleClock: last.clock, generation: mark.generation,
                frame: mark.frame, frames: nil, stream: take.stream, reason: contractV1Reason(reason),
                note: notes[seq]))
        }
        return records
    }

    private typealias Refusal = RecordingTakeV1DiscontinuityRefusal

    private static func validate(seqs: [Int], expected: Int) throws(Refusal) {
        guard seqs.count == expected else { throw .seqCount(expected: expected, actual: seqs.count) }
        for (index, seq) in seqs.enumerated() {
            guard seq >= 1 else { throw .invalidSeq(index: index, seq: seq) }
            guard index == 0 || seq > seqs[index - 1] else { throw .seqNotIncreasing(index: index, seq: seq) }
        }
    }

    private static func validate(_ take: RecordingTake) throws(Refusal) {
        guard MediaContractV1ID.matches(take.stream.rawValue) else { throw .invalidStream(take.stream) }
        let limit = TakeLedger.maximumSegmentsPerTake
        guard take.segments.count <= limit else { throw .tooManySegments(count: take.segments.count, limit: limit) }
        for (index, segment) in take.segments.enumerated() {
            guard MediaContractV1ID.matches(segment.clock.rawValue) else { throw .invalidSampleClock(segment: index) }
            for interval in segment.overflows where interval.frames > RecordingTakeV1DiscontinuityRecord.maximumFrames {
                throw .overflowFramesOutOfRange(segment: index, frames: interval.frames)
            }
        }
    }

    /// In ascending seq order, which is record order: the seqs are strictly increasing.
    private static func validate(notes: [Int: String], seqs: [Int]) throws(Refusal) {
        let numbered = notes.isEmpty ? [] : Set(seqs)
        for (seq, note) in notes.sorted(by: { $0.key < $1.key }) {
            guard numbered.contains(seq) else { throw .noteWithoutRecord(seq: seq) }
            let bytes = note.utf8.count
            guard MediaContractV1Note.isValid(note) else {
                throw .invalidNote(seq: seq, bytes: bytes)
            }
        }
    }

    private static func contractV1Reason(_ reason: RuntimeCaptureStopReason) -> String {
        switch reason {
        case .diskFull: "diskFull"
        case .deviceLost: "deviceLost"
        }
    }
}
