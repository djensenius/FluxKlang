//
//  PatchVariationEditor.swift
//  FluxKlang
//
//  Edits one patch's variations (#104 V2): add, capture current values as
//  deltas from the baseline, rename, duplicate, reorder and delete. Every edit
//  is all-or-nothing: it builds a candidate set, checks it with V1's
//  `validateStructure()`, and only then replaces the set. Deleting a variation
//  does not touch shows; a show that names it reports the broken link (SH1).
//

import Foundation

/// A structurally valid variation set under edit. It is built only by the
/// throwing factories, so `set` always passes `validateStructure()`.
///
/// The guarantee is structural only (what `PatchVariationExtension.read`
/// guarantees); no edit checks stored deltas against a parameter catalog.
/// A delta already stored for a parameter that is unknown or no longer live
/// survives `rename`, `duplicate`, `reorder` and `capture` of other parameters,
/// and recall (`recallPlan`) still refuses it.
struct PatchVariationEditor: Hashable, Sendable {
    private var storedSet: PatchVariationSet

    /// The edited set, in document order.
    var set: PatchVariationSet { storedSet }

    private init(validated set: PatchVariationSet) {
        storedSet = set
    }

    /// Refuses a set that fails `validateStructure()`.
    static func make(_ set: PatchVariationSet) throws(PatchVariationEditRefusal) -> PatchVariationEditor {
        do throws(PatchVariationError) {
            try set.validateStructure()
        } catch {
            throw .invalid(error)
        }
        return PatchVariationEditor(validated: set)
    }

    /// Reads `patch`'s set through `PatchVariationExtension.read`; never repairs.
    static func open(_ patch: ProjectPatch) throws(PatchVariationEditRefusal) -> PatchVariationEditor {
        do throws(PatchVariationError) {
            return PatchVariationEditor(validated: try PatchVariationExtension.read(from: patch))
        } catch {
            throw .invalid(error)
        }
    }

    /// `patch` with the edited set stored through `PatchVariationExtension.write`.
    func write(to patch: ProjectPatch) throws(PatchVariationEditRefusal) -> ProjectPatch {
        do throws(PatchVariationError) {
            return try PatchVariationExtension.write(storedSet, to: patch)
        } catch {
            throw .invalid(error)
        }
    }

    /// Appends an empty variation.
    mutating func add(_ id: PatchVariationID, label: String) throws(PatchVariationEditRefusal) {
        var candidate = storedSet
        candidate.variations.append(PatchVariation(id: id, label: label))
        try commit(candidate)
    }

    /// Sets `id`'s label; a label `PatchVariationLimits.isValidLabel` refuses leaves the set unchanged.
    mutating func rename(_ id: PatchVariationID, to label: String) throws(PatchVariationEditRefusal) {
        let position = try index(of: id)
        var candidate = storedSet
        candidate.variations[position].label = label
        try commit(candidate)
    }

    /// Inserts a copy of `source` (deltas and extension bags included) right
    /// after it, under the caller's `id` and `label`.
    mutating func duplicate(
        _ source: PatchVariationID, as id: PatchVariationID, label: String
    ) throws(PatchVariationEditRefusal) {
        let position = try index(of: source)
        var copy = storedSet.variations[position]
        copy.id = id
        copy.label = label
        var candidate = storedSet
        candidate.variations.insert(copy, at: position + 1)
        try commit(candidate)
    }

    /// Removes `id`. Shows that name it are not edited.
    mutating func delete(_ id: PatchVariationID) throws(PatchVariationEditRefusal) {
        let position = try index(of: id)
        var candidate = storedSet
        candidate.variations.remove(at: position)
        try commit(candidate)
    }

    /// Puts the variations in `order`, which must name every existing ID exactly once.
    mutating func reorder(_ order: [PatchVariationID]) throws(PatchVariationEditRefusal) {
        var remaining: [PatchVariationID: PatchVariation] = [:]
        for variation in storedSet.variations { remaining[variation.id] = variation }
        var reordered: [PatchVariation] = []
        for id in order {
            guard let variation = remaining.removeValue(forKey: id) else {
                throw storedSet[id] == nil ? .reorderUnknownVariation(id) : .reorderRepeatedVariation(id)
            }
            reordered.append(variation)
        }
        guard remaining.isEmpty else {
            throw .reorderIncomplete(expected: storedSet.variations.count, found: order.count)
        }
        var candidate = storedSet
        candidate.variations = reordered
        try commit(candidate)
    }

    /// Captures `parameters`' values from `current` into `id` as deltas from `baseline`.
    ///
    /// Every listed parameter must be known to `table`, live, present in `current`
    /// and `baseline`, and admitted by its descriptor; any refusal refuses the whole
    /// capture. A value equal to the baseline is not stored and removes an existing
    /// delta; a changed value updates the existing delta in place; a new one is
    /// appended in list order. Equality is `ParameterValue`'s (`Double` `==`, so
    /// -0.0 equals +0.0). Unlisted deltas are kept, including stale ones the
    /// table would now refuse (see the type's note).
    mutating func capture(
        _ parameters: [ParameterID], from current: [ParameterID: ParameterValue], into id: PatchVariationID,
        baseline: PatchBaseline, table: PatchParameterTable
    ) throws(PatchVariationEditRefusal) {
        let position = try index(of: id)
        do throws(PatchVariationError) {
            try baseline.validate(against: table)
        } catch {
            throw .invalid(error)
        }
        var deltas = storedSet.variations[position].deltas
        var seen = Set<ParameterID>()
        for parameter in parameters {
            guard seen.insert(parameter).inserted else { throw .repeatedParameter(parameter) }
            let value = try Self.admitted(parameter, from: current, into: id, table: table)
            guard let base = baseline.values[parameter] else {
                throw .invalid(.missingBaselineValue(id, parameter))
            }
            let existing = deltas.firstIndex { $0.parameter == parameter }
            if value == base {
                if let existing { deltas.remove(at: existing) }
            } else if let existing {
                deltas[existing].value = value
            } else {
                deltas.append(PatchParameterDelta(parameter: parameter, value: value))
            }
        }
        var candidate = storedSet
        candidate.variations[position].deltas = deltas
        try commit(candidate)
    }

    /// Unknown and non-live parameters are refused before a missing current value.
    private static func admitted(
        _ parameter: ParameterID, from current: [ParameterID: ParameterValue], into id: PatchVariationID,
        table: PatchParameterTable
    ) throws(PatchVariationEditRefusal) -> ParameterValue {
        guard let descriptor = table[parameter] else { throw .invalid(.unknownParameter(id, parameter)) }
        guard descriptor.controlClass == .live else {
            throw .invalid(.nonLiveParameter(id, parameter, descriptor.controlClass))
        }
        guard let value = current[parameter] else { throw .missingCurrentValue(parameter) }
        do throws(PatchVariationError) {
            try table.admit(value, for: parameter, in: id)
        } catch {
            throw .invalid(error)
        }
        return value
    }

    private func index(of id: PatchVariationID) throws(PatchVariationEditRefusal) -> Int {
        guard let position = storedSet.variations.firstIndex(where: { $0.id == id }) else {
            throw .invalid(.unknownVariation(id))
        }
        return position
    }

    private mutating func commit(_ candidate: PatchVariationSet) throws(PatchVariationEditRefusal) {
        do throws(PatchVariationError) {
            try candidate.validateStructure()
        } catch {
            throw .invalid(error)
        }
        storedSet = candidate
    }
}
