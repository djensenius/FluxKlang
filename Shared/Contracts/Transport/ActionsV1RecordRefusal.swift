//
//  ActionsV1RecordRefusal.swift
//  FluxKlang
//
//  Why a list of declarations cannot become the contract v1 `actions` header (#107 ACT1). In memory only;
//  nothing is dropped, deduplicated or serialized in its place.
//

/// The first offence `ActionsV1Record.make` finds, in this order: an empty list, too many actions (before any
/// per-action rule), then the first action ID that repeats an earlier one.
enum ActionsV1RecordRefusal: Error, Hashable, Sendable {
    /// No action. The header is optional, so a trace without actions omits it instead.
    case empty
    /// More than `ActionsV1Record.maximumActions`; carries the count.
    case tooManyActions(count: Int)
    /// The action ID repeats an earlier one (the later one is named); the checker refuses a repeated `actionId`.
    case duplicateActionID(ActionID)
}
