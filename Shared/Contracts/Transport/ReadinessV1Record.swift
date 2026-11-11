//
//  ReadinessV1Record.swift
//  FluxKlang
//
//  A readiness transition as the media contract v1 `readinessRecord` (#107 RXR1): exactly the
//  schema's fields, validated fail-closed and encoded deterministically. Pure: it writes no file and
//  assigns no trace sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `readinessRecord` of a contract v1 trace (media-contract.md §7). Built only by `make`.
///
/// Only the single transition is checked. That `from` is the action's current state, and that the action is
/// declared, are properties of the whole trace and stay the caller's responsibility. `reason` is free text with
/// the note rules; it is not derived from `ReadinessReason`.
struct ReadinessV1Record: Hashable, Sendable {
    static let kind = "readiness"
    /// The same bound as `RecordingTakeV1Record.maximumNoteBytes`; the schema needs only a non-empty note.
    /// It bounds both `reason` and `note`.
    static let maximumNoteBytes = RecordingTakeV1Record.maximumNoteBytes

    let seq: Int
    let actionID: ActionID
    let from: ReadinessState
    let to: ReadinessState
    /// Required when `to` is `failed` or `invalidated`; allowed, but not required, on other transitions.
    let reason: String?
    let note: String?

    /// Builds the record for `action`'s transition `from → to` at trace position `seq`, or throws the first
    /// refusal in the order `ReadinessV1RecordRefusal` documents. Never clamps or remaps a value.
    static func make(_ action: ActionID, from: ReadinessState, to: ReadinessState, seq: Int,
                     reason: String? = nil,
                     note: String? = nil) throws(ReadinessV1RecordRefusal) -> ReadinessV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(action.rawValue) else { throw .invalidActionID(action) }
        guard from.allowedNext.contains(to) else { throw .illegalTransition(from: from, to: to) }
        if let reason {
            guard isValidNote(reason) else { throw .invalidReason(bytes: reason.utf8.count) }
        } else if to == .failed || to == .invalidated {
            throw .missingReason(to: to)
        }
        if let note {
            guard isValidNote(note) else { throw .invalidNote(bytes: note.utf8.count) }
        }
        return ReadinessV1Record(seq: seq, actionID: action, from: from, to: to, reason: reason, note: note)
    }

    /// The TKX1 note rules: something other than whitespace, and at most `maximumNoteBytes` UTF-8 bytes.
    private static func isValidNote(_ text: String) -> Bool {
        text.utf8.count <= maximumNoteBytes && text.contains(where: { !$0.isWhitespace })
    }

    private init(seq: Int, actionID: ActionID, from: ReadinessState, to: ReadinessState, reason: String?,
                 note: String?) {
        self.seq = seq
        self.actionID = actionID
        self.from = from
        self.to = to
        self.reason = reason
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the
    /// schema's fields; `reason` and `note` are omitted when absent. Records built from the same inputs, with
    /// byte-identical `reason` and `note` text, encode to identical bytes. Swift `String` equality is canonical,
    /// so records whose text differs only in Unicode normalization (`"\u{00E9}"` vs `"e\u{0301}"`) compare
    /// equal but encode differently; text is never normalized.
    /// The output is bounded: an action ID of at most `ContractID.maximumLength` (128) bytes and a reason
    /// and note of at most `maximumNoteBytes` each.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension ReadinessV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, from, to, reason, note
        case actionID = "actionId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
