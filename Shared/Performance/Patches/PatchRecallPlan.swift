//
//  PatchRecallPlan.swift
//  FluxKlang
//
//  A parameter-only plan for moving one patch between its base and variations.
//  It names live catalog parameters and values only: no graph, node, port,
//  plugin, ramp or schedule, so recalling never restructures audio and cannot
//  cut notes or tails. Applying a plan belongs to later lanes.
//

import Foundation

/// One live parameter's value before and after a recall.
struct PatchParameterChange: Hashable, Sendable {
    let parameter: ParameterID
    let from: ParameterValue
    let to: ParameterValue
}

struct PatchRecallPlan: Hashable, Sendable {
    let patch: PatchID
    /// nil means the patch's baseline.
    let from: PatchVariationID?
    let to: PatchVariationID?
    /// Only parameters whose effective values differ, sorted by parameter ID.
    let changes: [PatchParameterChange]
}

enum PatchRecallPlanner {
    /// Plans `from` → `to` (nil = base) for `patch`, using only that patch's own
    /// stored variations. Refuses at the first problem in this order: the stored
    /// set, unknown `from` then `to`, the baseline, then `from`'s and `to`'s deltas
    /// in document order (unknown, non-live, invalid value, missing from baseline).
    ///
    /// `baseline` is supplied by the caller and is not tied to `patch`: `ProjectPatch`
    /// stores no parameter values, so nothing here checks that the baseline belongs to
    /// this patch. Callers must pass the base values of the same patch.
    static func plan(
        for patch: ProjectPatch,
        table: PatchParameterTable,
        baseline: PatchBaseline,
        from: PatchVariationID?,
        to: PatchVariationID?
    ) throws(PatchVariationError) -> PatchRecallPlan {
        try PatchVariationExtension.read(from: patch)
            .recallPlan(patch: patch.id, table: table, baseline: baseline, from: from, to: to)
    }

}

extension PatchVariationSet {
    /// The plan for this set as `patch`'s stored variations; see `PatchRecallPlanner`.
    func recallPlan(
        patch: PatchID,
        table: PatchParameterTable,
        baseline: PatchBaseline,
        from: PatchVariationID?,
        to: PatchVariationID?
    ) throws(PatchVariationError) -> PatchRecallPlan {
        try validateStructure()
        let source = try variation(from)
        let target = try variation(to)
        try baseline.validate(against: table)
        for variation in [source, target].compactMap(\.self) {
            for delta in variation.deltas {
                try table.admit(delta.value, for: delta.parameter, in: variation.id)
                guard baseline.values[delta.parameter] != nil else {
                    throw .missingBaselineValue(variation.id, delta.parameter)
                }
            }
        }
        let before = try baseline.effectiveValues(of: source)
        let after = try baseline.effectiveValues(of: target)
        // Both lists cover exactly the baseline's parameters, in the same order.
        let changes = zip(before, after).compactMap { old, new in
            old.value == new.value
                ? nil : PatchParameterChange(parameter: old.parameter, from: old.value, to: new.value)
        }
        return PatchRecallPlan(patch: patch, from: from, to: to, changes: changes)
    }

    private func variation(_ id: PatchVariationID?) throws(PatchVariationError) -> PatchVariation? {
        guard let id else { return nil }
        guard let found = self[id] else { throw .unknownVariation(id) }
        return found
    }
}
