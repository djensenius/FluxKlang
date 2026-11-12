//
//  DispatchV1Record.swift
//  FluxKlang
//
//  A dispatched event as the media contract v1 `dispatchRecord` (#107 DPR1): exactly the schema's fields,
//  validated fail-closed and encoded deterministically. Pure: it writes no file and assigns no trace sequence
//  number of its own; the caller passes `seq` and `streamSeq`.
//

import Foundation

/// The schema's `lane` values, declared in the media-contract.md §6.5 rank order (`release` 0, `transport` 1,
/// `state` 2, `content` 3). A test pins the order to the kernel's `EventLane`; `Shared/Contracts` uses no kernel type.
enum DispatchV1Lane: String, CaseIterable, Hashable, Sendable {
    case release, transport, state, content
}

/// One `dispatchRecord` of a contract v1 trace (media-contract.md §6.5). Built only by `make`.
///
/// Only the single record is checked. That the stream is declared, that records follow the dispatch order
/// `(frame, lane, streamOrdinal, streamSeq)`, that `streamSeq` strictly increases within a stream and the trace's
/// `ordering` coverage evidence are properties of the whole trace and stay with the checker and the trace assembler.
/// So do the numbers: the caller assigns `seq` and `streamSeq`, and nothing here numbers anything. `event` is the
/// caller's description of the dispatched event ("noteOn 60"); the contract fixes no format, so it follows only
/// the note rule and is never derived from a `KernelEvent`. `frame` and `lane` cannot be wrong by type, so they
/// have no refusal.
struct DispatchV1Record: Hashable, Sendable {
    static let kind = "dispatch"
    /// The same bound as `RecordingTakeV1Record.maximumNoteBytes`; the schema needs only a non-empty note.
    /// It bounds both `event` and `note`.
    static let maximumNoteBytes = MediaContractV1Note.maximumBytes

    let seq: Int
    let frame: Int64
    let lane: DispatchV1Lane
    let stream: StreamID
    /// At least 1; the schema sets no maximum, so the full `UInt64` range is written exactly.
    let streamSeq: UInt64
    let event: String
    let note: String?

    /// Builds the record of `event`, dispatched in `lane` on `stream` at `frame` as that stream's event number
    /// `streamSeq`, at trace position `seq`, or throws the first refusal in the order `DispatchV1RecordRefusal`
    /// documents. Never clamps or remaps a value.
    static func make( // swiftlint:disable:this function_parameter_count
        seq: Int, frame: Int64, lane: DispatchV1Lane, stream: StreamID, streamSeq: UInt64, event: String,
        note: String? = nil
    ) throws(DispatchV1RecordRefusal) -> DispatchV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(stream.rawValue) else { throw .invalidStream(stream) }
        guard streamSeq >= 1 else { throw .invalidStreamSeq(streamSeq) }
        guard MediaContractV1Note.isValid(event) else { throw .invalidEvent(bytes: event.utf8.count) }
        if let note {
            guard MediaContractV1Note.isValid(note) else { throw .invalidNote(bytes: note.utf8.count) }
        }
        return DispatchV1Record(seq: seq, frame: frame, lane: lane, stream: stream, streamSeq: streamSeq,
                                event: event, note: note)
    }

    private init(seq: Int, frame: Int64, lane: DispatchV1Lane, stream: StreamID, streamSeq: UInt64, event: String,
                 note: String?) {
        self.seq = seq
        self.frame = frame
        self.lane = lane
        self.stream = stream
        self.streamSeq = streamSeq
        self.event = event
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; `note` is omitted when absent. Records built from the same inputs, with byte-identical
    /// `event` and `note` text, encode to identical bytes. Swift `String` equality is canonical, so records whose
    /// text differs only in Unicode normalization (`"\u{00E9}"` vs `"e\u{0301}"`) compare equal but encode
    /// differently; text is never normalized.
    /// The output is bounded: a stream ID of at most `ContractID.maximumLength` (128) bytes and an event and note
    /// of at most `maximumNoteBytes` each.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension DispatchV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, frame, lane, stream, streamSeq, event, note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(frame, forKey: .frame)
        try container.encode(lane.rawValue, forKey: .lane)
        try container.encode(stream, forKey: .stream)
        try container.encode(streamSeq, forKey: .streamSeq)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
