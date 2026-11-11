//
//  TriggerOutcomeV1Record.swift
//  FluxKlang
//
//  A terminal trigger outcome as the media contract v1 `outcomeRecord` (#107 OXR1): exactly the
//  schema's fields, validated fail-closed and encoded deterministically. Pure: it writes no file and
//  assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `outcomeRecord` of a contract v1 trace (media-contract.md §6.4). Built only by `make`.
///
/// `TriggerOutcome.validateMediaShape()` already enforces the schema's per-result shape: dispatched results
/// carry both frames and no reason, `joined` alone has a positive `startOffsetFrames` equal to
/// `frame - assignedFrame`, `cancelled` and `rejectedStale` name a non-`musicalMap` generation kind, and
/// `dropped` names `late` (with `assignedFrame`) or `notReady`. Frames are `Int64` and the map revision a
/// `Generation`, so their schema bounds need no refusal here.
struct TriggerOutcomeV1Record: Hashable, Sendable {
    static let kind = "outcome"
    /// The same bound as `RecordingTakeV1Record.maximumNoteBytes`; the schema needs only a non-empty note.
    static let maximumNoteBytes = MediaContractV1Note.maximumBytes

    let seq: Int
    let triggerID: TriggerID
    let result: OutcomeResult
    let assignedFrame: Int64?
    let frame: Int64?
    /// Present only when non-zero, which the shape check allows only for `joined`.
    let startOffsetFrames: Int64?
    let musicalMap: Generation?
    /// A `GenerationKind` raw value for `cancelled` and `rejectedStale`, a `DropReason` raw value for `dropped`.
    let reason: String?
    let note: String?

    /// Builds the record for `outcome` at trace position `seq`, or throws the first refusal in the order
    /// `TriggerOutcomeV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(_ outcome: TriggerOutcome, seq: Int,
                     note: String? = nil) throws(TriggerOutcomeV1RecordRefusal) -> TriggerOutcomeV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(outcome.trigger.rawValue) else { throw .invalidTriggerID(outcome.trigger) }
        do {
            try outcome.validateMediaShape()
        } catch {
            throw .invalidShape(error)
        }
        let reason: String?
        switch (outcome.result, outcome.stale) {
        case (.cancelled, .generation(let key)), (.rejectedStale, .generation(let key)):
            reason = key.kind.rawValue
        case (.dropped, _):
            reason = outcome.reason?.rawValue
        default:
            // Dispatched results carry no reason. Unreachable for `cancelled` and `rejectedStale`: once
            // `validateMediaShape()` passes they always carry a `.generation` staleness.
            reason = nil
        }
        if let note {
            let bytes = note.utf8.count
            guard MediaContractV1Note.isValid(note) else {
                throw .invalidNote(bytes: bytes)
            }
        }
        return TriggerOutcomeV1Record(
            seq: seq, triggerID: outcome.trigger, result: outcome.result, assignedFrame: outcome.assignedFrame,
            frame: outcome.frame, startOffsetFrames: outcome.startOffsetFrames == 0 ? nil : outcome.startOffsetFrames,
            musicalMap: outcome.musicalMap, reason: reason, note: note)
    }

    private init(seq: Int, triggerID: TriggerID, result: OutcomeResult, assignedFrame: Int64?, frame: Int64?,
                 startOffsetFrames: Int64?, musicalMap: Generation?, reason: String?, note: String?) {
        self.seq = seq
        self.triggerID = triggerID
        self.result = result
        self.assignedFrame = assignedFrame
        self.frame = frame
        self.startOffsetFrames = startOffsetFrames
        self.musicalMap = musicalMap
        self.reason = reason
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; every optional field is omitted when absent. Records built from the same inputs, with
    /// byte-identical `note` text, encode to identical bytes. Swift `String` equality is canonical, so records
    /// whose notes differ only in Unicode normalization compare equal but encode differently; text is never
    /// normalized.
    /// The output is bounded: a trigger ID of at most `ContractID.maximumLength` (128) bytes and a note of
    /// at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension TriggerOutcomeV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, result, assignedFrame, frame, startOffsetFrames, musicalMap, reason, note
        case triggerID = "triggerId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(triggerID, forKey: .triggerID)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(assignedFrame, forKey: .assignedFrame)
        try container.encodeIfPresent(frame, forKey: .frame)
        try container.encodeIfPresent(startOffsetFrames, forKey: .startOffsetFrames)
        try container.encodeIfPresent(musicalMap, forKey: .musicalMap)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
