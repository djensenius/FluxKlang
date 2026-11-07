/// A capability dimension with its own local generation counter.
///
/// `resources`: maximum frames, bus count, enable state, channel layout or format changed. `sampleRate`: the rate
/// changed. `latency`: reported latency or tail changed (invalidates delay-compensation plans only). Case order is the
/// reporting order.
enum CapabilityAxis: String, CaseIterable, Sendable, Hashable {
    case resources
    case sampleRate
    case latency
}

/// Three local `Generation` counters, one per `CapabilityAxis`, compared by EQUALITY only (never ordinally).
///
/// Any combination of valid `Generation` values is valid, so the memberwise initialiser is deliberately available.
struct CapabilityGeneration: Hashable, Sendable {
    let resources: Generation
    let sampleRate: Generation
    let latency: Generation

    static let initial = CapabilityGeneration(
        resources: .initial, sampleRate: .initial, latency: .initial)

    /// A copy with ONLY `axis` stepped by exactly one; throws `.overflow` at `Generation.maximumValue`.
    func advancing(_ axis: CapabilityAxis) throws(RevisionError) -> CapabilityGeneration {
        switch axis {
        case .resources:
            return CapabilityGeneration(resources: try resources.next(), sampleRate: sampleRate, latency: latency)
        case .sampleRate:
            return CapabilityGeneration(resources: resources, sampleRate: try sampleRate.next(), latency: latency)
        case .latency:
            return CapabilityGeneration(resources: resources, sampleRate: sampleRate, latency: try latency.next())
        }
    }

    /// The axes where `self` differs from `live`, in `CapabilityAxis.allCases` order.
    func staleAxes(comparedTo live: CapabilityGeneration) -> [CapabilityAxis] {
        CapabilityAxis.allCases.filter { axis in
            switch axis {
            case .resources: resources != live.resources
            case .sampleRate: sampleRate != live.sampleRate
            case .latency: latency != live.latency
            }
        }
    }
}
