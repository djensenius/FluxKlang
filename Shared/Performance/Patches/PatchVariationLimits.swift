//
//  PatchVariationLimits.swift
//  FluxKlang
//
//  Bounds and typed refusals for patch variations, plus the catalog-free
//  structural check every stored set must pass.
//

import Foundation

enum PatchVariationLimits {
    static let currentVersion = 1
    static let maximumVariations = 128
    static let maximumDeltasPerVariation = 4096
    static let maximumLabelBytes = 256

    /// Non-empty, at most 256 UTF-8 bytes, no leading or trailing whitespace and
    /// no control (Cc), format (Cf), line (Zl) or paragraph (Zp) separator scalars.
    static func isValidLabel(_ label: String) -> Bool {
        let scalars = label.unicodeScalars
        guard let first = scalars.first, let last = scalars.last,
              label.utf8.count <= maximumLabelBytes,
              !first.properties.isWhitespace, !last.properties.isWhitespace else { return false }
        return !scalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }
}

/// Why a variation set, baseline or recall is refused. Checks stop at the first
/// refusal in document order (variations, then each variation's deltas).
enum PatchVariationError: Error, Hashable, Sendable {
    /// The stored value is not a version-1 variation set (wrong JSON type, bad ID, unknown
    /// unit, a version that is not an integer of at least 1...).
    case malformed
    /// The stored version is newer than this reader; it is preserved and read-only.
    case futureVersionReadOnly(Int)
    case tooManyVariations(count: Int, maximum: Int)
    case tooManyDeltas(PatchVariationID, count: Int, maximum: Int)
    case invalidLabel(PatchVariationID)
    case duplicateVariation(PatchVariationID)
    case duplicateDelta(PatchVariationID, ParameterID)
    /// A nil variation means the baseline.
    case unknownParameter(PatchVariationID?, ParameterID)
    case nonLiveParameter(PatchVariationID?, ParameterID, ControlClass)
    case invalidValue(PatchVariationID?, ParameterID, ParameterValueError)
    case unknownVariation(PatchVariationID)
    case missingBaselineValue(PatchVariationID, ParameterID)
}

extension PatchVariationSet {
    /// Counts, identity uniqueness and labels; needs no parameter catalog.
    func validateStructure() throws(PatchVariationError) {
        guard variations.count <= PatchVariationLimits.maximumVariations else {
            throw .tooManyVariations(count: variations.count, maximum: PatchVariationLimits.maximumVariations)
        }
        var seen = Set<PatchVariationID>()
        for variation in variations {
            guard seen.insert(variation.id).inserted else { throw .duplicateVariation(variation.id) }
            try variation.validateStructure()
        }
    }
}

extension PatchVariation {
    func validateStructure() throws(PatchVariationError) {
        guard PatchVariationLimits.isValidLabel(label) else { throw .invalidLabel(id) }
        guard deltas.count <= PatchVariationLimits.maximumDeltasPerVariation else {
            throw .tooManyDeltas(id, count: deltas.count, maximum: PatchVariationLimits.maximumDeltasPerVariation)
        }
        var seen = Set<ParameterID>()
        for delta in deltas where !seen.insert(delta.parameter).inserted {
            throw .duplicateDelta(id, delta.parameter)
        }
    }
}
