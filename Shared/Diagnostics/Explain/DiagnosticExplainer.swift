//
//  DiagnosticExplainer.swift
//  FluxKlang
//
//  Turns one `NeutralSnapshot` into grounded facts: measured versus declared
//  parameters, unavailable routes, open diagnostics and, when the snapshot left
//  something out, one fact saying so. Pure and deterministic: no model, no
//  provider, no clock, and nothing outside the snapshot is read.
//

/// The facts of one snapshot, in report order, with what the fact cap left out.
struct ExplanationReport: Hashable, Sendable {
    /// At most `ExplainLimits.maximumFacts`, in `ExplanationFact.precedes` order.
    private(set) var facts: [ExplanationFact]
    /// Facts derived but not kept because of the cap; never silently dropped.
    private(set) var omitted: Int
    /// The snapshot's own truncation counts, copied unchanged.
    private(set) var snapshotTruncation: NeutralSnapshot.Truncation

    fileprivate init(facts: [ExplanationFact], omitted: Int, snapshotTruncation: NeutralSnapshot.Truncation) {
        self.facts = facts
        self.omitted = omitted
        self.snapshotTruncation = snapshotTruncation
    }
}

enum DiagnosticExplainer {
    /// Derives every fact, sorts them into report order, keeps the first `limits.maximumFacts` and counts the rest
    /// as omitted. The truncation fact, when there is one, sorts first, so a cap never removes it. It cannot
    /// refuse: `ExplainLimits` values are validated when built, so it does not throw.
    static func facts(from snapshot: NeutralSnapshot, limits: ExplainLimits) -> ExplanationReport {
        var candidates: [ExplanationFact] = []
        if ExplanationFact.isIncomplete(snapshot.truncation) {
            candidates.append(.truncation(snapshot.truncation))
        }
        for parameter in snapshot.parameters {
            candidates.append(.parameter(parameter, in: snapshot))
        }
        for route in snapshot.unavailableRoutes {
            candidates.append(.route(route))
        }
        for diagnostic in snapshot.diagnostics {
            candidates.append(.diagnostic(diagnostic))
        }
        let ordered = candidates.sorted(by: ExplanationFact.precedes)
        let kept = min(ordered.count, limits.maximumFacts)
        return ExplanationReport(
            facts: Array(ordered.prefix(kept)), omitted: ordered.count - kept,
            snapshotTruncation: snapshot.truncation
        )
    }
}
