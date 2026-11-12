//
//  AnchorV1Record.swift
//  FluxKlang
//
//  A clock anchor as the media contract v1 `anchorRecord` (#84 AXR1): exactly the schema's fields,
//  validated fail-closed and encoded deterministically. Pure: it writes no file and assigns no trace
//  sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `anchorRecord` of a contract v1 trace (media-contract.md §7). Built only by `make`.
///
/// Only the single anchor is checked: `seq`, the clock ID's shape, non-negative musical ticks and the note.
/// Every rule that needs the trace's state stays with the checker and the future trace assembler: that the
/// generation is current, that the clocks advance within the drift bound, that the transport generation is
/// current, the resume tick, one `loopIteration` per wrap, and the exact `transport`/`musicalTicks` pairing
/// against the trace.
///
/// The record has no `musicalMap` field (the trace's own counter supplies it), so the stamp's `musicalMap` is
/// dropped. A `loopIteration` of 0 is not written; an absent value reads as 0.
///
/// Host ticks appear because the contract's anchor needs them (M13). A trace is an analysis document, not
/// persisted media, and host ticks are only meaningful within one process run.
struct AnchorV1Record: Hashable, Sendable {
    static let kind = "anchor"
    /// The same bound as `RecordingTakeV1Record.maximumNoteBytes`; the schema needs only a non-empty note.
    static let maximumNoteBytes = MediaContractV1Note.maximumBytes

    let seq: Int
    let sampleClock: ClockID
    let generation: Generation
    let frame: Int64
    let hostTicks: UInt64
    /// Present exactly when `musicalTicks` is.
    let transport: Generation?
    /// At least 0.
    let musicalTicks: Int64?
    /// `nil` when the stamp's value is 0.
    let loopIteration: UInt32?
    let note: String?

    /// Builds the record for `anchor` at trace position `seq`, or throws the first refusal in the order
    /// `AnchorV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(_ anchor: ClockAnchor, seq: Int,
                     note: String? = nil) throws(AnchorV1RecordRefusal) -> AnchorV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        let clock = anchor.sample.clock
        guard MediaContractV1ID.matches(clock.rawValue) else { throw .invalidSampleClock(clock) }
        if let musical = anchor.musical {
            guard musical.ticks >= 0 else { throw .negativeMusicalTicks(musical.ticks) }
        }
        if let note {
            guard MediaContractV1Note.isValid(note) else { throw .invalidNote(bytes: note.utf8.count) }
        }
        let musical = anchor.musical
        return AnchorV1Record(seq: seq, sampleClock: clock, generation: anchor.sample.generation,
                              frame: anchor.sample.frame, hostTicks: anchor.host.ticks,
                              transport: musical?.transport, musicalTicks: musical?.ticks,
                              loopIteration: musical.flatMap { $0.loopIteration == 0 ? nil : $0.loopIteration },
                              note: note)
    }

    private init(seq: Int, sampleClock: ClockID, generation: Generation, frame: Int64, hostTicks: UInt64,
                 transport: Generation?, musicalTicks: Int64?, loopIteration: UInt32?, note: String?) {
        self.seq = seq
        self.sampleClock = sampleClock
        self.generation = generation
        self.frame = frame
        self.hostTicks = hostTicks
        self.transport = transport
        self.musicalTicks = musicalTicks
        self.loopIteration = loopIteration
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; `transport`, `musicalTicks`, `loopIteration` and `note` are omitted when absent.
    /// Records built from the same inputs, with byte-identical `note` text, encode to identical bytes; text is
    /// never normalized. The output is bounded: a clock ID of at most `ContractID.maximumLength` (128) bytes
    /// and a note of at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension AnchorV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, sampleClock, generation, frame, hostTicks, transport, musicalTicks, loopIteration, note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(sampleClock.rawValue, forKey: .sampleClock)
        try container.encode(generation, forKey: .generation)
        try container.encode(frame, forKey: .frame)
        try container.encode(hostTicks, forKey: .hostTicks)
        try container.encodeIfPresent(transport, forKey: .transport)
        try container.encodeIfPresent(musicalTicks, forKey: .musicalTicks)
        try container.encodeIfPresent(loopIteration, forKey: .loopIteration)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
