//
//  TriggerV1Record.swift
//  FluxKlang
//
//  A trigger stamp as the media contract v1 `triggerRecord` (#107 TXR1): exactly the schema's fields,
//  validated fail-closed and encoded deterministically. Pure: it writes no file and assigns no trace
//  sequence number of its own; the caller passes `seq`.
//

import Foundation

/// One `triggerRecord` of a contract v1 trace (media-contract.md §3, §6). Built only by `make`.
///
/// Only what the stamp alone decides is checked: the IDs, 1...8 requirements (no `musicalMap` kind, valid subjects,
/// no duplicate key), the target's numbers and the note. Everything that needs the trace's state stays with
/// `TriggerStamp.validate` and the checker: declared clocks, the primary clock and a context in `requires`, the
/// transport for musical targets, the retroactive and lateness bounds, and the `nextBoundary` rules. `make` never
/// calls `validate`, so it accepts a stamp that `validate` refuses for a clock reason.
///
/// The record has no field for `latePolicy` or `retroactiveMs` (the action's `late` carries them), for
/// `stoppedPolicy` (the v1 trace has no such field) or for `loopIteration`, so `make` drops them. `target` is omitted
/// exactly when the caller passes the action's declared `quantize` and it equals the stamp's target: the checker then
/// reads the action's value. Whether `quantize` is the declared value is the caller's fact; `make` only compares it.
///
/// `originHostTicks` is written because the contract's trigger carries its origin host time (M3). M13 and §15 make
/// host ticks and timeline records transient, never persisted: a trace is an analysis document, not persisted media.
struct TriggerV1Record: Hashable, Sendable {
    static let kind = "trigger"
    /// The same bound as the other v1 builders; the schema needs only a non-empty note.
    static let maximumNoteBytes = MediaContractV1Note.maximumBytes

    let seq: Int
    let triggerID: TriggerID
    let actionID: ActionID
    let originHostTicks: UInt64
    let horizonFrame: Int64
    /// 1...8 entries.
    let requires: [GenerationKey: Generation]
    /// Nil: omitted, the action's `quantize` applies.
    let target: TriggerTarget?
    let note: String?

    /// Builds the record for `stamp` at trace position `seq`, or throws the first refusal in the order
    /// `TriggerV1RecordRefusal` documents. Never clamps, sorts-and-drops or remaps a value.
    static func make(_ stamp: TriggerStamp, seq: Int, quantize: TriggerTarget? = nil,
                     note: String? = nil) throws(TriggerV1RecordRefusal) -> TriggerV1Record {
        guard seq >= 1 else { throw .invalidSeq(seq) }
        guard MediaContractV1ID.matches(stamp.id.rawValue) else { throw .invalidTriggerID(stamp.id) }
        guard MediaContractV1ID.matches(stamp.action.rawValue) else { throw .invalidActionID(stamp.action) }
        guard !stamp.requires.isEmpty else { throw .noRequirements }
        guard stamp.requires.count <= TriggerStamp.maximumRequirements else {
            throw .tooManyRequirements(stamp.requires.count)
        }
        let requires = try generations(of: stamp.requires)
        try check(stamp.target)
        if let note {
            guard MediaContractV1Note.isValid(note) else { throw .invalidNote(bytes: note.utf8.count) }
        }
        return TriggerV1Record(seq: seq, triggerID: stamp.id, actionID: stamp.action,
                               originHostTicks: stamp.originHost.ticks, horizonFrame: stamp.horizonFrame,
                               requires: requires, target: quantize == stamp.target ? nil : stamp.target, note: note)
    }

    private static func generations(of requirements: [GenerationRequirement])
        throws(TriggerV1RecordRefusal) -> [GenerationKey: Generation] {
        var requires: [GenerationKey: Generation] = [:]
        for requirement in requirements {
            let key = requirement.key
            guard key.kind != .musicalMap else { throw .musicalMapRequirement(key) }
            guard MediaContractV1ID.matches(key.subject.rawValue) else { throw .invalidRequirementSubject(key) }
            guard requires.updateValue(requirement.generation, forKey: key) == nil else {
                throw .duplicateRequirement(key)
            }
        }
        return requires
    }

    private static func check(_ target: TriggerTarget) throws(TriggerV1RecordRefusal) {
        switch target {
        case .grid(let ticks): guard ticks >= 1 else { throw .invalidGrid(ticks) }
        case .musical(let ticks): guard ticks >= 0 else { throw .negativeMusicalTicks(ticks) }
        case .sample, .asap: break
        }
    }

    private init(seq: Int, triggerID: TriggerID, actionID: ActionID, originHostTicks: UInt64, horizonFrame: Int64,
                 requires: [GenerationKey: Generation], target: TriggerTarget?, note: String?) {
        self.seq = seq
        self.triggerID = triggerID
        self.actionID = actionID
        self.originHostTicks = originHostTicks
        self.horizonFrame = horizonFrame
        self.requires = requires
        self.target = target
        self.note = note
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`), holding exactly the schema's
    /// fields; `target` and `note` are omitted when absent and `requires` is a `"kind/subject": generation` map.
    /// Records built from the same inputs, with byte-identical `note` text, encode to identical bytes; text is never
    /// normalized. The output is bounded: two IDs and at most 8 requirement subjects of at most
    /// `ContractID.maximumLength` (128) bytes each, and a note of at most `maximumNoteBytes`.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension TriggerV1Record: Encodable {
    private enum CodingKeys: String, CodingKey {
        case seq, kind, originHostTicks, horizonFrame, requires, target, note
        case triggerID = "triggerId"
        case actionID = "actionId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(triggerID, forKey: .triggerID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(originHostTicks, forKey: .originHostTicks)
        try container.encode(horizonFrame, forKey: .horizonFrame)
        let members = Dictionary(uniqueKeysWithValues: requires.map { ($0.key.description, $0.value) })
        try container.encode(members, forKey: .requires)
        try container.encodeIfPresent(target.map(TargetShape.init), forKey: .target)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

/// The schema's `$defs.target`: each case writes only its own fields.
private struct TargetShape: Encodable {
    let target: TriggerTarget

    private enum CodingKeys: String, CodingKey {
        case timeBase, gridTicks, atTicks, atFrame
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .grid(let ticks):
            try container.encode("musical", forKey: .timeBase)
            try container.encode(ticks, forKey: .gridTicks)
        case .musical(let ticks):
            try container.encode("musical", forKey: .timeBase)
            try container.encode(ticks, forKey: .atTicks)
        case .sample(let frame):
            try container.encode("sample", forKey: .timeBase)
            try container.encode(frame, forKey: .atFrame)
        case .asap:
            try container.encode("asap", forKey: .timeBase)
        }
    }
}
