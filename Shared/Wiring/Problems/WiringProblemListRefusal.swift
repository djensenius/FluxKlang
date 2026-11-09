//
//  WiringProblemListRefusal.swift
//  FluxKlang
//
//  Why the problem list of a draft cannot be made (#101 WGP1). Only `WiringProblemList.make(active:draft:)` refuses;
//  the list of a set of errors and the list of a graph are total.
//

/// Why the problem list of a draft is refused. Nothing is changed.
enum WiringProblemListRefusal: Error, Hashable, Sendable {
    /// The draft graph cannot be made: the draft edits another graph or revision, the active graph repeats a node or
    /// edge ID, the active graph or the graph the edits make exceeds the limits, or the edits do not apply. The
    /// preview refusal is carried verbatim.
    case preview(WiringPreviewRefusal)
}
