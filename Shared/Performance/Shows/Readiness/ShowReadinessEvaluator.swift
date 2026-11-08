//
//  ShowReadinessEvaluator.swift
//  FluxKlang
//
//  The facts a pre-show readiness verdict is built from (#103). All of them are values the caller already holds:
//  nothing is loaded, armed or started here, and nothing outside these values is read. `evaluate` is declared next
//  to the verdict it builds.
//

/// The facts a verdict is built from: the library, the setlist to check, the action-set reports and the worklist of
/// that library. A worklist target that names a slot holding no chart reference is ignored, and a report for an
/// action set no entry references is ignored.
struct ShowReadinessFacts: Equatable, Sendable {
    let library: ShowLibrary
    let setlist: SetlistID
    /// At most one report per action set, in no required order. A second report for one set is refused, including a
    /// set no entry references.
    let reports: [ActionSetReadinessReport]
    /// The missing charts and the count of other broken links of `library`.
    let worklist: ShowRecoveryWorklist
}

enum ShowReadinessEvaluator {
    /// A valid action-set library holds far fewer sets; the bound refuses an oversized report list before the
    /// setlist is looked up or the reports are indexed.
    static let maximumReports = 4_096
}
