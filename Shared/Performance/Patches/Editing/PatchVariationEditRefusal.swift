//
//  PatchVariationEditRefusal.swift
//  FluxKlang
//
//  Typed refusals for editing (#104 V2) and repairing a patch's variations,
//  and the typed record of every item a salvage drops. A refused edit or
//  repair leaves its input unchanged.
//

import Foundation

/// Why an edit, discard or salvage is refused.
enum PatchVariationEditRefusal: Error, Hashable, Sendable {
    /// A check shared with V1 refused: a structural limit, label, identity,
    /// catalog admission or baseline lookup (the wrapped error names which).
    case invalid(PatchVariationError)
    /// A captured parameter has no value in the supplied current values.
    case missingCurrentValue(ParameterID)
    /// A capture list names the same parameter twice.
    case repeatedParameter(ParameterID)
    /// A reorder list names an ID the set does not contain.
    case reorderUnknownVariation(PatchVariationID)
    /// A reorder list names the same ID twice.
    case reorderRepeatedVariation(PatchVariationID)
    /// A reorder list has no unknown or repeated IDs but omits some (`found` < `expected`).
    case reorderIncomplete(expected: Int, found: Int)
    /// The patch has no variations key, so there is nothing to discard or salvage.
    case nothingToRepair
    /// The stored value is a newer version; it is never discarded or salvaged.
    case futureVersionNotRepairable(Int)
    /// Salvage needs a version-1 object whose `variations` is an array; use discard instead.
    case notSalvageable(PatchVariationSalvageBlocker)
}

/// Why a stored value has no items salvage could keep.
enum PatchVariationSalvageBlocker: Hashable, Sendable {
    /// The stored value is not a JSON object.
    case notAnObject
    /// `version` is missing, not an integer or below 1 (V1 reads it as malformed).
    case malformedVersion
    /// `variations` is missing or not an array.
    case variationsNotAnArray
}

/// One stored item salvage did not keep. Indices are positions in the stored
/// arrays (variations, then the variation's deltas), so every drop is locatable.
enum PatchVariationSalvageDrop: Hashable, Sendable {
    /// The set's own `extensions` member is not an object of JSON values.
    case malformedSetExtensions
    /// The variation is not an object, or its ID, label or `deltas` array does not decode.
    case malformedVariation(index: Int)
    case invalidLabel(index: Int, PatchVariationID)
    /// A variation with this ID was already kept earlier in document order.
    case duplicateVariation(index: Int, PatchVariationID)
    /// The set already kept `PatchVariationLimits.maximumVariations` variations.
    case overVariationLimit(index: Int, PatchVariationID)
    /// The delta does not decode (bad parameter ID, unit or value).
    case malformedDelta(PatchVariationID, index: Int)
    /// A delta for this parameter was already kept earlier in the variation.
    case duplicateDelta(PatchVariationID, index: Int, ParameterID)
    /// The variation already kept `PatchVariationLimits.maximumDeltasPerVariation` deltas.
    case overDeltaLimit(PatchVariationID, index: Int, ParameterID)
}
