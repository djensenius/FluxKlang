//
//  TimelineV1Record.swift
//  FluxKlang
//
//  The media contract v1 trace's top-level `timeline` array (#84 TRC1): built records in order, validated
//  fail-closed and encoded deterministically. Pure: it writes no file and reads no clock.
//

import Foundation

/// The `timeline` array of a contract v1 trace. Built only by `make`.
///
/// The records carry their own `seq`; `make` validates, and never assigns, renumbers, sorts or fills a gap: the
/// list must already be `1...n` in order. Checked here are only the rules the list itself decides, the ones the
/// checker enforces without replaying: that `seq` runs `1...n`, and that a `triggerId`, a `takeId` and an
/// `exportId` are each unique (the three ID spaces are separate).
///
/// Not checked here, because they need a header or the trace state: that a trigger names a declared action, that
/// an outcome names an earlier trigger, that a record names a declared stream or clock, generation currency and
/// readiness transitions. The checker, and later the full trace assembler, decide those.
struct TimelineV1Record: Hashable, Sendable {
    /// The schema sets no maximum. 262,144 is four times `MIDICaptureLog.maximumCaptures` (65,536), the longest
    /// list any producer holds today, and keeps the one-pass encoding of a trace finite; a longer recording is
    /// split into several traces.
    static let maximumEntries = 262_144

    /// The caller's order, never sorted.
    let entries: [TimelineV1Entry]

    /// Builds the array from `entries`, or throws the first refusal in the order `TimelineV1RecordRefusal`
    /// documents.
    static func make(_ entries: [TimelineV1Entry]) throws(TimelineV1RecordRefusal) -> TimelineV1Record {
        guard !entries.isEmpty else { throw .empty }
        guard entries.count <= maximumEntries else { throw .tooManyEntries(count: entries.count) }
        for (index, entry) in entries.enumerated() where entry.seq != index + 1 {
            throw .sequenceBreak(index: index, expected: index + 1, found: entry.seq)
        }
        try checkUniqueIDs(entries)
        return TimelineV1Record(entries: entries)
    }

    private static func checkUniqueIDs(_ entries: [TimelineV1Entry]) throws(TimelineV1RecordRefusal) {
        var triggers = Set<TriggerID>()
        var takes = Set<TakeID>()
        var exports = Set<ExportID>()
        for entry in entries {
            switch entry {
            case .trigger(let record):
                guard triggers.insert(record.triggerID).inserted else { throw .duplicateTriggerID(record.triggerID) }
            case .take(let record):
                guard takes.insert(record.takeID).inserted else { throw .duplicateTakeID(record.takeID) }
            case .export(let record):
                guard exports.insert(record.exportID).inserted else { throw .duplicateExportID(record.exportID) }
            case .anchor, .generation, .outcome, .readiness, .discontinuity, .dispatch, .midiCapture:
                continue
            }
        }
    }

    private init(entries: [TimelineV1Entry]) {
        self.entries = entries
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`): the entries in order, each
    /// written as its own record's `encodedJSON()` writes it. Identical input encodes to identical bytes. It
    /// throws only if an entry refuses to encode, which the built records do not.
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }
}

extension TimelineV1Record: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}
