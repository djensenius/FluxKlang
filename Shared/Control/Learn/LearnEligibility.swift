import Foundation

/// Why a target cannot be learned. Hazardous targets are never included here; an explicit,
/// permissioned include path is a later slice.
enum LearnBlockReason: Hashable, Sendable {
    case hazardous
    /// Any other non-live class (structural, safety, proposal).
    case notLive(ControlClass)
    /// Listed in the caller's exclusion set (for example `learnExcludedByDefault`).
    case excluded
}

/// The Learn-owned exclusion policy, passed in as a value. Class rules come from the
/// descriptor; `excluded` adds explicit parameter IDs on top of them.
struct LearnEligibilityPolicy: Hashable, Sendable {
    static let maximumExcluded = 4096

    let excluded: Set<ParameterID>

    init(excluded: Set<ParameterID> = []) throws(LearnRefusal) {
        guard excluded.count <= Self.maximumExcluded else { throw .tooManyExcluded(excluded.count) }
        self.excluded = excluded
    }

    /// `nil` when the target may be learned. Class rules take precedence over the exclusion set.
    func blockReason(for descriptor: ParameterDescriptor) -> LearnBlockReason? {
        switch descriptor.controlClass {
        case .live: return excluded.contains(descriptor.id) ? .excluded : nil
        case .hazardous: return .hazardous
        case .structural, .safety, .proposal: return .notLive(descriptor.controlClass)
        }
    }
}
