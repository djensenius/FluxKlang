//
//  ShowRecoveryDecision.swift
//  FluxKlang
//
//  The explicit choices of a missing-chart recovery and the typed refusal of a batch (#106 SH4). Nothing is guessed:
//  a replacement exists only because the caller wrote it into a decision.
//

enum ShowRecoveryDecision: Hashable, Sendable {
    /// Every currently missing reference to `from` moves to the asset `to` and keeps its own page.
    case relinkAsset(from: AssetID, to: AssetID)
    /// One missing reference becomes the given chart: an explicit asset and page.
    case relinkTarget(ShowRecoveryTarget, to: ChartReference)
    /// Removes every currently missing reference to the asset.
    case clearAsset(AssetID)
    /// Removes one missing reference.
    case clearTarget(ShowRecoveryTarget)
}

/// Why one decision, or the whole batch, was refused. `ShowRefusal` is wrapped, never extended.
enum ShowRecoveryReason: Error, Hashable, Sendable {
    /// The batch has more than `ShowChartRecovery.maximumDecisions` decisions; carries the full count.
    case tooManyDecisions(Int)
    /// The asset has no currently missing reference, or the target's chart is available. Carries the asset.
    case notMissing(AssetID)
    /// The address holds no chart: an unknown song or part, a part of another song, or a cleared chart.
    case noSuchTarget(ShowRecoveryTarget)
    /// The catalog's own refusal of a replacement, such as `chartUnavailable`.
    case show(ShowRefusal)
}

/// A refused batch changes nothing. `index` is the first refused decision; for `tooManyDecisions` it is the first
/// decision that does not fit.
struct ShowRecoveryRefusal: Error, Hashable, Sendable {
    let index: Int
    let reason: ShowRecoveryReason
}
