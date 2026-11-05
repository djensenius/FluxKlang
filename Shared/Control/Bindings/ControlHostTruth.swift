import Foundation

/// The host's current truth for resolving bindings: its parameter catalog and the current value of each
/// parameter. The caller builds it fresh from the host; a binding never caches a descriptor or a value, so a
/// removed, retyped, reclassed or re-ranged target is judged by what the host reports now.
/// The only initializer validates and storage is private, so a truth can be neither unbounded nor edited after it
/// was checked. The catalog's descriptor IDs are already unique (`ParameterCatalog` refuses duplicates). Non-finite
/// host values are kept as reported; resolving against one refuses only that binding (`nonFinite`).
struct ControlHostTruth: Hashable, Sendable {
    /// The most current values a truth may carry, matching the catalog's own descriptor cap.
    static let maximumValues = 4096
    private let storedCatalog: ParameterCatalog
    private let storedValues: [ParameterID: ParameterValue]

    var catalog: ParameterCatalog { storedCatalog }
    var values: [ParameterID: ParameterValue] { storedValues }

    init(catalog: ParameterCatalog, values: [ParameterID: ParameterValue]) throws(ControlHostTruthRefusal) {
        guard values.count <= Self.maximumValues else { throw .tooManyValues(values.count) }
        storedCatalog = catalog
        storedValues = values
    }

    /// The target's current descriptor and value. A target missing from the catalog is refused before a missing
    /// value; neither is ever defaulted.
    func target(_ id: ParameterID) throws(ControlBindingRefusal) -> (ParameterDescriptor, ParameterValue) {
        guard let descriptor = catalog[id] else { throw .targetMissing(id) }
        guard let value = values[id] else { throw .valueUnavailable(id) }
        return (descriptor, value)
    }
}

/// Host truth that cannot be built.
enum ControlHostTruthRefusal: Error, Hashable, Sendable {
    /// More than `ControlHostTruth.maximumValues` values were supplied.
    case tooManyValues(Int)
}

extension ControlRecord where Fields == ControlBindingFields {
    /// Resolves one input against host truth. Host-truth refusals (missing target, then missing value) come first,
    /// even for a stale controller; then `resolve(input:current:descriptor:state:)` checks unit, class, range,
    /// curve and pickup against the fresh descriptor and clamps to it. Refusals leave the caller's state as it was.
    func resolve(input: ControlInput, truth: ControlHostTruth,
                 state: PickupState) throws(ControlBindingRefusal) -> PickupResolution {
        let (descriptor, current) = try truth.target(fields.target)
        return try resolve(input: input, current: current, descriptor: descriptor, state: state)
    }
}
