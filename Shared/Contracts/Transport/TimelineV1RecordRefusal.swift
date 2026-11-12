//
//  TimelineV1RecordRefusal.swift
//  FluxKlang
//
//  Why a list of built records cannot become the contract v1 trace's `timeline` array (#84 TRC1). In memory only;
//  nothing is renumbered, sorted, dropped or serialized in its place.
//

/// The first offence `TimelineV1Record.make` finds, in this order: an empty list, a list over the bound, the first
/// entry whose `seq` is not its position, then the first repeated trigger, take or export ID in timeline order
/// (one pass over the entries: the repeat met first wins, whichever kind it is; the refusal names the ID, not the
/// entry that repeats it).
enum TimelineV1RecordRefusal: Error, Equatable, Sendable {
    /// No entries; the schema's `timeline` has `minItems: 1`.
    case empty
    /// More than `TimelineV1Record.maximumEntries` entries; checked before any entry.
    case tooManyEntries(count: Int)
    /// The entry at 0-based `index` has `seq` `found`, not `expected` (`index + 1`).
    case sequenceBreak(index: Int, expected: Int, found: Int)
    /// A trigger record repeats this `triggerId`, already used by an earlier one; no index is carried.
    case duplicateTriggerID(TriggerID)
    /// A take record repeats this `takeId`, already used by an earlier one; no index is carried.
    case duplicateTakeID(TakeID)
    /// An export record repeats this `exportId`, already used by an earlier one; no index is carried.
    case duplicateExportID(ExportID)
}
