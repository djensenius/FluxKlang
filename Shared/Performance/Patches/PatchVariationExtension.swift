//
//  PatchVariationExtension.swift
//  FluxKlang
//
//  Stores a patch's `PatchVariationSet` under one key of `ProjectPatch.extensions`.
//  Writes replace only that key; every other key and unknown field is untouched.
//  A newer version is preserved as-is and is read-only.
//

import Foundation

/// What a patch's variation key holds.
enum PatchVariationContent: Hashable, Sendable {
    case absent
    case current(PatchVariationSet)
    /// A newer version this reader must not interpret, edit or drop.
    case future(version: Int)
}

enum PatchVariationExtension {
    static let key = "fluxklang.patchVariations"

    /// Classifies the stored value; a current set must also pass `validateStructure()`.
    static func content(of patch: ProjectPatch) throws(PatchVariationError) -> PatchVariationContent {
        guard let raw = patch.extensions?[key] else { return .absent }
        guard case .object(let members) = raw else { throw .malformed }
        switch try version(members["version"]) {
        case PatchVariationLimits.currentVersion: break
        case let newer: return .future(version: newer)
        }
        let set: PatchVariationSet
        do {
            let data = try ContractCoding.makeEncoder().encode(raw)
            set = try ContractCoding.decode(PatchVariationSet.self, from: data)
        } catch {
            throw .malformed
        }
        try set.validateStructure()
        return .current(set)
    }

    /// The stored version by numeric value, matching `JSONValue`'s number equality:
    /// an integral `.int`, `.uint` or `.double` of at least 1, clamped to `Int.max`.
    /// Anything else (non-integral, zero, negative, not a number) is malformed.
    private static func version(_ value: JSONValue?) throws(PatchVariationError) -> Int {
        let version: Int
        switch value {
        case .int(let number): version = Int(clamping: number)
        case .uint(let number): version = Int(clamping: number)
        case .double(let number) where number.isFinite && number.rounded() == number:
            version = Int(exactly: number) ?? (number > 0 ? Int.max : Int.min)
        default: throw .malformed
        }
        guard version >= PatchVariationLimits.currentVersion else { throw .malformed }
        return version
    }

    /// The patch's set; an absent key reads as an empty set.
    static func read(from patch: ProjectPatch) throws(PatchVariationError) -> PatchVariationSet {
        switch try content(of: patch) {
        case .absent: PatchVariationSet()
        case .current(let set): set
        case .future(let version): throw .futureVersionReadOnly(version)
        }
    }

    /// Returns `patch` with `set` stored under `key`; an empty set removes the key.
    /// Refuses if the stored value is a future version or otherwise unreadable, so
    /// nothing this reader cannot interpret is ever dropped or rewritten. This fails
    /// closed: a stored set that is malformed or fails `validateStructure()` (for
    /// example 129 variations) cannot be replaced or cleared through `write` either.
    /// `PatchVariationRepair.discard` and `PatchVariationRepair.salvage` are the deliberate repair paths, each an
    /// explicit call; neither touches a future version.
    static func write(_ set: PatchVariationSet, to patch: ProjectPatch) throws(PatchVariationError) -> ProjectPatch {
        let existing = try content(of: patch)
        if case .future(let version) = existing { throw .futureVersionReadOnly(version) }
        try set.validateStructure()
        if set.isEmpty, existing == .absent { return patch }
        var extensions = patch.extensions ?? [:]
        if set.isEmpty {
            extensions[key] = nil
        } else {
            extensions[key] = try encode(set)
        }
        var result = patch
        result.extensions = extensions.isEmpty ? nil : extensions
        return result
    }

    private static func encode(_ set: PatchVariationSet) throws(PatchVariationError) -> JSONValue {
        for variation in set.variations {
            for delta in variation.deltas where !delta.value.value.isFinite {
                throw .invalidValue(variation.id, delta.parameter, .nonFinite)
            }
        }
        do {
            let data = try ContractCoding.makeEncoder().encode(set)
            return try ContractCoding.decode(JSONValue.self, from: data)
        } catch {
            throw .malformed
        }
    }
}
