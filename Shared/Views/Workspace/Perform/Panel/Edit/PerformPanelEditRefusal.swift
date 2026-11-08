//
//  PerformPanelEditRefusal.swift
//  FluxKlang
//
//  Typed refusals of the perform panel editor (#102 PNE1).
//

/// Why an edit builds no result. The input list is never changed by an edit, refused or not.
///
/// Every operation checks in this order and the first failing check decides: the entry cap of the input list
/// (`layout(.tooManyEntries)`); then the operation's own input (`indexOutOfRange` for `adding`; `targetNotFound` for
/// the others; for `moving` the target first, then the index); then `PerformPanelLayout.make`, whose refusal is
/// wrapped unchanged in `layout` and keeps the order documented on `PerformPanelRefusal`.
enum PerformPanelEditRefusal: Error, Equatable, Sendable {
    /// No entry of the input list uses this parameter.
    case targetNotFound(ParameterID)
    /// `index` is outside `0...largest`. `largest` is the entry count for `adding` and the last position for `moving`.
    case indexOutOfRange(index: Int, largest: Int)
    /// The edited list, or the input list when it is over the entry cap, is refused by the layout.
    case layout(PerformPanelRefusal)
}
