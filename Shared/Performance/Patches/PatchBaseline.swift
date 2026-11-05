//
//  PatchBaseline.swift
//  FluxKlang
//
//  The values a patch's variations are measured against, and the catalog view
//  that admits them. Only `.live` parameters ever take part.
//

import Foundation

/// A parameter catalog indexed once by ID, for admitting baseline and delta values.
struct PatchParameterTable: Sendable {
    private let descriptors: [ParameterID: ParameterDescriptor]
    /// Every descriptor, in catalog order.
    let catalogOrder: [ParameterDescriptor]

    init(_ catalog: ParameterCatalog) {
        var descriptors: [ParameterID: ParameterDescriptor] = [:]
        for descriptor in catalog.parameters where descriptors[descriptor.id] == nil {
            descriptors[descriptor.id] = descriptor
        }
        self.descriptors = descriptors
        catalogOrder = catalog.parameters
    }

    subscript(id: ParameterID) -> ParameterDescriptor? { descriptors[id] }

    /// Refuses unknown and non-live parameters and any value the descriptor's
    /// unit, range, step or ceiling rejects.
    func admit(
        _ value: ParameterValue, for parameter: ParameterID, in variation: PatchVariationID?
    ) throws(PatchVariationError) {
        guard let descriptor = descriptors[parameter] else { throw .unknownParameter(variation, parameter) }
        guard descriptor.controlClass == .live else {
            throw .nonLiveParameter(variation, parameter, descriptor.controlClass)
        }
        do throws(ParameterValueError) {
            try descriptor.check(value)
        } catch {
            throw .invalidValue(variation, parameter, error)
        }
    }
}

/// One parameter's value.
struct PatchParameterSetting: Hashable, Sendable {
    let parameter: ParameterID
    let value: ParameterValue
}

/// The containing patch's own values: the base every variation overrides.
struct PatchBaseline: Hashable, Sendable {
    let values: [ParameterID: ParameterValue]

    /// Admits every value against `table`, in `ParameterID` order.
    init(_ values: [ParameterID: ParameterValue], table: PatchParameterTable) throws(PatchVariationError) {
        self.values = values
        try validate(against: table)
    }

    /// Every live parameter at its descriptor's default.
    static func defaults(_ table: PatchParameterTable) -> PatchBaseline {
        var values: [ParameterID: ParameterValue] = [:]
        for descriptor in table.catalogOrder where descriptor.controlClass == .live {
            values[descriptor.id] = ParameterValue(value: descriptor.defaultValue, unit: descriptor.unit)
        }
        return PatchBaseline(unchecked: values)
    }

    private init(unchecked values: [ParameterID: ParameterValue]) {
        self.values = values
    }

    func validate(against table: PatchParameterTable) throws(PatchVariationError) {
        for parameter in values.keys.sorted() {
            if let value = values[parameter] { try table.admit(value, for: parameter, in: nil) }
        }
    }

    /// The baseline overlaid by `variation`'s deltas (nil means the baseline itself),
    /// sorted by parameter ID. Every delta must name a baseline parameter.
    func effectiveValues(of variation: PatchVariation?) throws(PatchVariationError) -> [PatchParameterSetting] {
        var result = values
        if let variation {
            for delta in variation.deltas {
                guard values[delta.parameter] != nil else {
                    throw .missingBaselineValue(variation.id, delta.parameter)
                }
                result[delta.parameter] = delta.value
            }
        }
        return result.keys.sorted().compactMap { id in
            result[id].map { PatchParameterSetting(parameter: id, value: $0) }
        }
    }
}
