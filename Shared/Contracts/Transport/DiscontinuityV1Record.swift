//
//  DiscontinuityV1Record.swift
//  FluxKlang
//
//  A clock, transport or stream event as the media contract v1 `discontinuityRecord` (#109 DXR1): exactly
//  the schema's fields, validated fail-closed and encoded deterministically. Pure: it writes no file and
//  assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One non-take `discontinuityRecord` of a contract v1 trace (media-contract.md §8.4). Built only by `make`.
///
/// `overflow` and `captureStopped` belong to a take and are built by the take's own discontinuity builder
/// (slice TKX2); `sampleJump` is not built yet. Each `Event` case carries exactly the §8.4 data its type
/// needs, so `previousFrame` and `hostTicks` appear only on `clockRestart`, `frames` only on `underrun`, a
/// stream only where §8.4 names one, and `reason` never. The types already guarantee the schema's other
/// bounds, so they have no refusal here: `frame` and `previousFrame` are `Int64`, `hostTicks` is a `UInt64`,
/// and `generation` is in range (`Generation`). That the generation is current, that a `clockRestart` follows
/// its sample clock bump, that a `loopWrap` falls at the loop end and that a stream is declared with the right
/// direction are properties of the whole trace and stay the caller's responsibility.
struct DiscontinuityV1Record: Hashable, Sendable {
    /// The event and its type-specific data.
    enum Event: Hashable, Sendable {
        /// A new sample clock generation begins at `hostTicks`; the old one ended at `previousFrame`.
        case clockRestart(hostTicks: UInt64, previousFrame: Int64)
        /// The playback stream ran out of prefetched data for `frames` frames.
        case underrun(StreamID, frames: Int64)
        case sourceLost(StreamID)
        case sourceRestored(StreamID)
        /// The transport jumped (one per `locate` bump).
        case locate
        /// A loop iteration boundary.
        case loopWrap
        /// The stream's format or MIDI protocol changed.
        case formatChange(StreamID)

        /// The schema's `type` value.
        var type: String {
            switch self {
            case .clockRestart: "clockRestart"
            case .underrun: "underrun"
            case .sourceLost: "sourceLost"
            case .sourceRestored: "sourceRestored"
            case .locate: "locate"
            case .loopWrap: "loopWrap"
            case .formatChange: "formatChange"
            }
        }

        var stream: StreamID? {
            switch self {
            case .underrun(let stream, _), .sourceLost(let stream), .sourceRestored(let stream),
                 .formatChange(let stream):
                stream
            case .clockRestart, .locate, .loopWrap:
                nil
            }
        }
    }

    static let kind = "discontinuity"
    /// The schema's `frames` maximum, 2^32 − 1.
    static let maximumFrames: Int64 = 4_294_967_295
    /// The same bound as `RecordingTakeV1Record.maximumNoteBytes`; the schema needs only a non-empty note.
    static let maximumNoteBytes = RecordingTakeV1Record.maximumNoteBytes

    let seq: Int
    let event: Event
    let sampleClock: ClockID
    let generation: Generation
    /// The event's frame on `sampleClock` at `generation` (for `clockRestart`, the new generation's frame).
    let frame: Int64
    let note: String?

    /// Builds the record for `event` at `frame` of `sampleClock`'s `generation` at trace position `seq`, or
    /// throws the first refusal in the order `DiscontinuityV1RecordRefusal` documents. Never clamps or remaps
    /// a value.
    static func make(_ event: Event, sampleClock: ClockID, generation: Generation, frame: Int64, seq: Int,
                     note: String? = nil) throws(DiscontinuityV1RecordRefusal) -> DiscontinuityV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(sampleClock.rawValue) else { throw .invalidSampleClock(sampleClock) }
        if let stream = event.stream {
            guard MediaContractV1ID.matches(stream.rawValue) else { throw .invalidStream(stream) }
        }
        if case .underrun(_, let frames) = event {
            guard (1...maximumFrames).contains(frames) else { throw .framesOutOfRange(frames) }
        }
        if let note {
            let bytes = note.utf8.count
            guard bytes <= maximumNoteBytes, note.contains(where: { !$0.isWhitespace }) else {
                throw .invalidNote(bytes: bytes)
            }
        }
        return DiscontinuityV1Record(seq: seq, event: event, sampleClock: sampleClock, generation: generation,
                                     frame: frame, note: note)
    }

    private init(seq: Int, event: Event, sampleClock: ClockID, generation: Generation, frame: Int64,
                 note: String?) {
        self.seq = seq
        self.event = event
        self.sampleClock = sampleClock
        self.generation = generation
        self.frame = frame
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; fields the event does not carry, and an absent `note`, are omitted. Records built from
    /// the same inputs, with byte-identical `note` text, encode to identical bytes. Swift `String` equality is
    /// canonical, so records whose notes differ only in Unicode normalization compare equal but encode
    /// differently; text is never normalized. The output is bounded: IDs of at most `ContractID.maximumLength`
    /// (128) bytes and a note of at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension DiscontinuityV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, type, sampleClock, generation, frame, frames, hostTicks, previousFrame, stream, note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(event.type, forKey: .type)
        try container.encode(sampleClock, forKey: .sampleClock)
        try container.encode(generation, forKey: .generation)
        try container.encode(frame, forKey: .frame)
        switch event {
        case .clockRestart(let hostTicks, let previousFrame):
            try container.encode(hostTicks, forKey: .hostTicks)
            try container.encode(previousFrame, forKey: .previousFrame)
        case .underrun(_, let frames):
            try container.encode(frames, forKey: .frames)
        case .sourceLost, .sourceRestored, .locate, .loopWrap, .formatChange:
            break
        }
        try container.encodeIfPresent(event.stream, forKey: .stream)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
