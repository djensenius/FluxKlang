//
//  PatchVariationRepair.swift
//  FluxKlang
//
//  The deliberate repair paths V1 left as a follow-up (`PatchVariationExtension`
//  refuses to read or overwrite a stored set it cannot interpret). Repair is
//  never part of reading: each path is an explicit call, and neither ever
//  touches a future version.
//
//  - `discard` removes only the variations key; every other extension key and
//    patch field is left exactly as it was.
//  - `salvage` keeps every valid item in document order up to the limits and
//    reports every item it drops with a typed reason.
//

import Foundation

/// A salvaged patch and every item salvage dropped, in document order.
struct PatchVariationSalvage: Hashable, Sendable {
    let patch: ProjectPatch
    let drops: [PatchVariationSalvageDrop]

    fileprivate init(patch: ProjectPatch, drops: [PatchVariationSalvageDrop]) {
        self.patch = patch
        self.drops = drops
    }
}

enum PatchVariationRepair {
    /// `patch` without its variations key (current, malformed or over-limit).
    /// Refuses an absent key and a future version.
    static func discard(from patch: ProjectPatch) throws(PatchVariationEditRefusal) -> ProjectPatch {
        guard patch.extensions?[PatchVariationExtension.key] != nil else { throw .nothingToRepair }
        if case .future(let version)? = try? PatchVariationExtension.content(of: patch) {
            throw .futureVersionNotRepairable(version)
        }
        return removingKey(from: patch)
    }

    /// Rebuilds a version-1 set from the valid items of the stored value.
    ///
    /// A set V1 already reads is returned unchanged with no drops. Otherwise
    /// variations are kept in document order when they decode, have a valid
    /// label and an ID not already kept, until 128 are kept; each kept
    /// variation keeps its deltas that decode and name a parameter not already
    /// kept, until 4,096. Unknown fields and extension bags of kept items are
    /// kept. Refuses an absent key, a future version, and a value with no
    /// items to keep (not an object, malformed version, `variations` not an array).
    static func salvage(_ patch: ProjectPatch) throws(PatchVariationEditRefusal) -> PatchVariationSalvage {
        guard let raw = patch.extensions?[PatchVariationExtension.key] else { throw .nothingToRepair }
        switch try? PatchVariationExtension.content(of: patch) {
        case .future(let version)?: throw .futureVersionNotRepairable(version)
        case .current?: return PatchVariationSalvage(patch: patch, drops: [])
        case .absent?, nil: break
        }
        guard case .object(let members) = raw else { throw .notSalvageable(.notAnObject) }
        try requireCurrentVersion(members["version"], of: patch)
        guard case .array(let items) = members["variations"] else { throw .notSalvageable(.variationsNotAnArray) }

        var drops: [PatchVariationSalvageDrop] = []
        var header = members
        header["variations"] = .array([])
        if let extensions = header["extensions"], extensions != .null,
           decode([String: JSONValue].self, from: extensions) == nil {
            drops.append(.malformedSetExtensions)
            header["extensions"] = nil
        }
        guard var set = decode(PatchVariationSet.self, from: .object(header)) else {
            throw .invalid(.malformed)
        }
        set.variations = salvageVariations(items, drops: &drops)
        do throws(PatchVariationError) {
            return PatchVariationSalvage(
                patch: try PatchVariationExtension.write(set, to: removingKey(from: patch)), drops: drops
            )
        } catch {
            throw .invalid(error)
        }
    }

    private static func salvageVariations(
        _ items: [JSONValue], drops: inout [PatchVariationSalvageDrop]
    ) -> [PatchVariation] {
        var kept: [PatchVariation] = []
        var keptIDs = Set<PatchVariationID>()
        for (index, item) in items.enumerated() {
            guard case .object(var fields) = item, case .array(let rawDeltas)? = fields["deltas"] else {
                drops.append(.malformedVariation(index: index))
                continue
            }
            fields["deltas"] = .array([])
            guard var variation = decode(PatchVariation.self, from: .object(fields)) else {
                drops.append(.malformedVariation(index: index))
                continue
            }
            guard PatchVariationLimits.isValidLabel(variation.label) else {
                drops.append(.invalidLabel(index: index, variation.id))
                continue
            }
            guard !keptIDs.contains(variation.id) else {
                drops.append(.duplicateVariation(index: index, variation.id))
                continue
            }
            guard kept.count < PatchVariationLimits.maximumVariations else {
                drops.append(.overVariationLimit(index: index, variation.id))
                continue
            }
            keptIDs.insert(variation.id)
            variation.deltas = salvageDeltas(rawDeltas, of: variation.id, drops: &drops)
            kept.append(variation)
        }
        return kept
    }

    private static func salvageDeltas(
        _ items: [JSONValue], of id: PatchVariationID, drops: inout [PatchVariationSalvageDrop]
    ) -> [PatchParameterDelta] {
        var kept: [PatchParameterDelta] = []
        var keptParameters = Set<ParameterID>()
        for (index, item) in items.enumerated() {
            guard let delta = decode(PatchParameterDelta.self, from: item) else {
                drops.append(.malformedDelta(id, index: index))
                continue
            }
            guard !keptParameters.contains(delta.parameter) else {
                drops.append(.duplicateDelta(id, index: index, delta.parameter))
                continue
            }
            guard kept.count < PatchVariationLimits.maximumDeltasPerVariation else {
                drops.append(.overDeltaLimit(id, index: index, delta.parameter))
                continue
            }
            keptParameters.insert(delta.parameter)
            kept.append(delta)
        }
        return kept
    }

    /// Classifies `version` with V1's own reader by probing an otherwise empty
    /// set, so salvage and reading can never disagree about versions.
    private static func requireCurrentVersion(
        _ version: JSONValue?, of patch: ProjectPatch
    ) throws(PatchVariationEditRefusal) {
        var members: [String: JSONValue] = ["variations": .array([])]
        members["version"] = version
        var probe = patch
        probe.extensions = [PatchVariationExtension.key: .object(members)]
        guard case .current? = try? PatchVariationExtension.content(of: probe) else {
            throw .notSalvageable(.malformedVersion)
        }
    }

    private static func removingKey(from patch: ProjectPatch) -> ProjectPatch {
        var result = patch
        result.extensions?[PatchVariationExtension.key] = nil
        if result.extensions?.isEmpty == true { result.extensions = nil }
        return result
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) -> T? {
        guard let data = try? ContractCoding.makeEncoder().encode(value) else { return nil }
        return try? ContractCoding.decode(type, from: data)
    }
}
