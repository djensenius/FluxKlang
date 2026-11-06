//
//  ShowTransitionPlanner.swift
//  FluxKlang
//
//  Builds a `ShowTransitionPlan` from a source stop, the patch actually
//  loaded, a target stop and the caller's project inputs (#106 SH2). Pure and deterministic: equal inputs
//  give equal plans, inputs are taken by value and never changed, and nothing
//  is recalled, armed, fired, scheduled or timed. Every problem becomes a typed
//  block in the plan; planning itself never throws.
//

/// The patch actually loaded before a move, with its active variation (`nil` = base). Tracked by the caller, not
/// derived from the source stop: a blocked cross-patch move leaves the previous patch loaded.
struct ShowActivePatch: Hashable, Sendable {
    let patch: PatchID
    let variation: PatchVariationID?
}

/// One patch's recall inputs, passed unchanged to `PatchRecallPlanner.plan`.
struct ShowPatchRecallSource: Sendable {
    let patch: ProjectPatch
    let table: PatchParameterTable
    /// The base values of this same patch (`PatchRecallPlanner` cannot check that).
    let baseline: PatchBaseline
}

/// The project's action sets and the readiness inputs of `ActionSetReadinessAggregate.evaluate`.
struct ShowActionSetSource: Sendable {
    let library: PerformanceActionSetLibrary
    let actions: [ProjectMediaAction]
    let readiness: ActionReadiness
    let ledger: GenerationLedger
    /// Stale trigger requirements per member; see `ActionSetReadinessAggregate.evaluate`.
    var stale: [ActionID: [GenerationKey]] = [:]
}

/// What the planner may read. Built through `make`, which refuses ambiguity and excess.
struct ShowTransitionContext: Sendable {
    /// Lookup only; never iterated.
    private let patches: [PatchID: ShowPatchRecallSource]
    /// `nil` when the caller passes no action sets: a linked set is then `actionSetSourceUnavailable`.
    let actionSets: ShowActionSetSource?

    /// Refuses more than `ShowLimits.maximumCatalogPatches` patch sources and two sources for one patch.
    static func make(patches: [ShowPatchRecallSource] = [],
                     actionSets: ShowActionSetSource? = nil) throws(ShowRefusal) -> ShowTransitionContext {
        guard patches.count <= ShowLimits.maximumCatalogPatches else { throw .catalogTooLarge(.patches, patches.count) }
        var byID: [PatchID: ShowPatchRecallSource] = [:]
        for source in patches where byID.updateValue(source, forKey: source.patch.id) != nil {
            throw .duplicatePatch(source.patch.id)
        }
        return ShowTransitionContext(patches: byID, actionSets: actionSets)
    }

    func patchSource(_ id: PatchID) -> ShowPatchRecallSource? { patches[id] }
}

enum ShowTransitionPlanner {
    /// Plans `source` → `target` while `active` is loaded. `source` is `nil` when the cursor had no stop before the
    /// move and only names the stop; `active` is `nil` when no patch is loaded. Only the target's effective links
    /// (`ShowStop.links`) are planned.
    ///
    /// - Patch: unlinked when the target links no patch, meaning no patch change (whatever is loaded stays loaded,
    ///   also when nothing is). Otherwise, in this order: a target `unknownPatch` problem is an `unresolvedLink`;
    ///   no active patch or a different one is `requiresStructuralActivationReview(from: active?.patch, ...)`; a
    ///   target `unknownVariation` problem is an `unresolvedLink`; a patch without a recall source in `context` is
    ///   `recallSourceUnavailable`; then `PatchRecallPlanner.plan` from the active variation to the target's, whose
    ///   refusal (including an active variation the patch no longer has) is `patchRecallRefused`.
    /// - Action set: unlinked when none is linked; an `unknownActionSet` problem is an `unresolvedLink`; no
    ///   `context.actionSets` is `actionSetSourceUnavailable`; then the set is resolved (a refusal is
    ///   `actionSetRefused`) and its readiness report is planned, ready or not. It is never fired.
    /// - Chart: unlinked, the available reference, or a missing chart as an `unresolvedLink(.chart)`.
    static func plan(from source: ShowStop?, to target: ShowStop, active: ShowActivePatch?,
                     in context: ShowTransitionContext) -> ShowTransitionPlan {
        ShowTransitionPlan(from: source.map(ShowStopReference.init), to: ShowStopReference(target),
                           patch: patchStep(to: target, active: active, in: context),
                           actionSet: actionSetStep(to: target, in: context),
                           chart: chartStep(to: target))
    }

    private static func patchStep(to target: ShowStop, active: ShowActivePatch?,
                                  in context: ShowTransitionContext) -> ShowTransitionStep<PatchRecallPlan> {
        let links = target.links.links
        let problems = target.links.problems
        guard let patch = links.patch else { return .unlinked }
        if problems.contains(.unknownPatch(patch)) { return .blocked(.unresolvedLink(.unknownPatch(patch))) }
        guard let active, active.patch == patch else {
            return .blocked(.requiresStructuralActivationReview(from: active?.patch, to: patch))
        }
        if let variation = links.variation, problems.contains(.unknownVariation(patch, variation)) {
            return .blocked(.unresolvedLink(.unknownVariation(patch, variation)))
        }
        guard let recall = context.patchSource(patch) else { return .blocked(.recallSourceUnavailable(patch)) }
        do {
            return try .planned(PatchRecallPlanner.plan(for: recall.patch, table: recall.table,
                                                        baseline: recall.baseline,
                                                        from: active.variation, to: links.variation))
        } catch {
            return .blocked(.patchRecallRefused(patch, error))
        }
    }

    private static func actionSetStep(to target: ShowStop, in context: ShowTransitionContext)
        -> ShowTransitionStep<ActionSetReadinessReport> {
        guard let id = target.links.links.actionSet else { return .unlinked }
        if target.links.problems.contains(.unknownActionSet(id)) {
            return .blocked(.unresolvedLink(.unknownActionSet(id)))
        }
        guard let sets = context.actionSets else { return .blocked(.actionSetSourceUnavailable(id)) }
        do {
            let resolved = try sets.library.resolve(id, in: sets.actions)
            return .planned(ActionSetReadinessAggregate.evaluate(resolved, readiness: sets.readiness,
                                                                 ledger: sets.ledger, stale: sets.stale))
        } catch {
            return .blocked(.actionSetRefused(id, error))
        }
    }

    private static func chartStep(to target: ShowStop) -> ShowTransitionStep<ChartReference> {
        switch target.links.chart {
        case nil: .unlinked
        case let .available(chart): .planned(chart)
        case let .missing(chart, reason): .blocked(.unresolvedLink(.chart(chart, reason)))
        }
    }
}
