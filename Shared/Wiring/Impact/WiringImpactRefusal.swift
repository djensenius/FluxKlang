//
//  WiringImpactRefusal.swift
//  FluxKlang
//
//  Why an edit impact cannot be previewed (#101 WPV1). A refusal carries the existing refusal unchanged, changes
//  nothing, and is not worded here: the caller words it.
//

/// Why `WiringImpact.make` refused. The checks run in the order the cases are listed: the draft graph cannot be
/// formed (`preview`), the baseline graph's validation stops before checking wires (`baselineUncheckable`), the
/// composer refuses the gesture (`compose`, `edit` or `node`), the graph after the gesture cannot be checked
/// (`resultUncheckable`).
enum WiringImpactRefusal: Error, Hashable, Sendable {
    /// The input draft does not check against the active graph, exactly as `WiringReviewDiff.make` refuses it.
    case preview(WiringPreviewRefusal)
    /// The draft graph before the gesture has an error that stops validation before any wire is checked.
    case baselineUncheckable(GraphValidationError)
    /// `WiringDraftComposer` refused the connect.
    case compose(WiringComposeRefusal)
    /// `WiringRemoveComposer` or `WiringMoveComposer` refused the gesture.
    case edit(WiringEditRefusal)
    /// `WiringNodeComposer` refused the gesture.
    case node(WiringNodeRefusal)
    /// The draft graph after the gesture has an error that stops validation before any wire is checked.
    case resultUncheckable(GraphValidationError)
}
