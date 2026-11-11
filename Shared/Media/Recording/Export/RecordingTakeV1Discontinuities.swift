//
//  RecordingTakeV1Discontinuities.swift
//  FluxKlang
//
//  A cleared take's own media contract v1 `discontinuityRecord`s (#110 TKX2): one `overflow` per
//  padded interval and the `captureStopped` of a non-`user` stop, as `DiscontinuityV1Record`s (#110 DUN1),
//  validated fail-closed. Pure: it writes no file and numbers nothing itself; the caller passes the seqs.
//

import Foundation

/// Why a cleared take's discontinuities cannot become contract v1 records. In memory only; nothing is
/// clamped, remapped or serialized in its place. `RecordingTakeV1Discontinuities.make` throws the first
/// offence in this order: the seqs (their count, then by lowest index a seq below 1 or not above the one
/// before), the stream, the segment count, then per segment (lowest index first) its `sampleClock` and its
/// overflows' frame counts, then the notes in ascending seq order. Seqs, stream, segment count and clock
/// follow `RecordingTakeV1RecordRefusal`'s relative order, so a take whose `takeRecord` is refused for one of
/// them yields no discontinuity record either. Every record is then built by `DiscontinuityV1Record.make`,
/// whose refusals these checks already cover; were one still thrown, it maps to the matching case here.
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
    /// (`DiscontinuityV1Record.maximumFrames`), or, defensively, a count outside 1...maximum. The ledger reads
    /// overflow counts as `UInt32` and `OverflowInterval` holds at least one frame, so only a hand-built segment
    /// reaches this.
    case overflowFramesOutOfRange(segment: Int, frames: Int64)
    /// The note for this seq is empty, all whitespace, or longer than `RecordingTakeV1Record.maximumNoteBytes`
    /// UTF-8 bytes.
    case invalidNote(seq: Int, bytes: Int)
    /// A note is keyed by a seq that numbers none of the records.
    case noteWithoutRecord(seq: Int)
}

/// Builds a cleared take's own `overflow` and `captureStopped` records as `DiscontinuityV1Record`s, so they
/// encode exactly as that type documents: identical input gives identical bytes. Their order is fixed: every
/// segment in order, each one's overflows in ascending frame order, then the `captureStopped` (none for a
/// `user` stop). A trace interleaves them with other records, so they are not numbered consecutively: the
/// caller asks `count(of:)`, picks that many strictly increasing seqs, and passes them to `make` in that order.
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
        throws(RecordingTakeV1DiscontinuityRefusal) -> [DiscontinuityV1Record] {
        let take = clearance.take
        let expected = count(of: clearance)
        try validate(seqs: seqs, expected: expected)
        try validate(take)
        try validate(notes: notes, seqs: seqs)
        var records: [DiscontinuityV1Record] = []
        records.reserveCapacity(expected)
        func append(_ event: DiscontinuityV1Record.Event, segment: Int, sampleClock: ClockID, generation: Generation,
                    frame: Int64) throws(Refusal) {
            let index = records.count
            let seq = seqs[index]
            do {
                records.append(try DiscontinuityV1Record.make(event, sampleClock: sampleClock, generation: generation,
                                                              frame: frame, seq: seq, note: notes[seq]))
            } catch {
                throw refusal(error, index: index, seq: seq, segment: segment)
            }
        }
        for (index, segment) in take.segments.enumerated() {
            for interval in segment.overflows {
                try append(.overflow(take.stream, frames: interval.frames), segment: index,
                           sampleClock: segment.clock, generation: segment.generation, frame: interval.startFrame)
            }
        }
        // `captureStopped` holds only a mark whose stop has a capture reason, and a take is never empty.
        if let mark = take.captureStopped, let reason = mark.reason.captureReason, let last = take.segments.last {
            try append(.captureStopped(take.stream, reason: reason), segment: take.segments.count - 1,
                       sampleClock: last.clock, generation: mark.generation, frame: mark.frame)
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
            for interval in segment.overflows where interval.frames > DiscontinuityV1Record.maximumFrames {
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

    /// The take's case for the offence `DiscontinuityV1Record.make` found in the `index`-th record, numbered
    /// `seq`, of `segment`. The take checks above run first and cover every such offence, so through `make`
    /// this is never reached.
    private static func refusal(_ error: DiscontinuityV1RecordRefusal, index: Int, seq: Int,
                                segment: Int) -> Refusal {
        switch error {
        case .invalidSeq: .invalidSeq(index: index, seq: seq)
        case .invalidSampleClock: .invalidSampleClock(segment: segment)
        case .invalidStream(let stream): .invalidStream(stream)
        case .framesOutOfRange(let frames): .overflowFramesOutOfRange(segment: segment, frames: frames)
        case .invalidNote(let bytes): .invalidNote(seq: seq, bytes: bytes)
        }
    }
}
