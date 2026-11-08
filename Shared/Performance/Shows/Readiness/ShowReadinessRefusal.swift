//
//  ShowReadinessRefusal.swift
//  FluxKlang
//
//  Why a readiness verdict cannot be built from the supplied facts (#103). The checks run in the order the cases
//  are listed: too many reports, then an unknown setlist, then a repeated report.
//

enum ShowReadinessRefusal: Error, Equatable, Sendable {
    /// More reports than `ShowReadinessEvaluator.maximumReports`; the payload is the count supplied.
    case tooManyReports(Int)
    /// The library holds no setlist with this ID.
    case unknownSetlist(SetlistID)
    /// Two reports name the same action set; the payload is the first set seen twice, in report order.
    case duplicateReport(ActionSetID)
}
