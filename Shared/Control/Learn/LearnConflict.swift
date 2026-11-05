import Foundation

enum LearnConflictKind: String, Codable, Hashable, Sendable, CaseIterable {
    case sameSource, sameTarget, sameSourceAndTarget
}

/// An existing binding that shares the proposed binding's source, target or both.
struct LearnConflict: Hashable, Sendable {
    let binding: BindingID
    let kind: LearnConflictKind
}

/// How the caller confirms against conflicts. `replace` must name exactly the current conflict set.
enum LearnConflictResolution: Hashable, Sendable {
    case refuse
    case replace(Set<BindingID>)
}

enum LearnConflicts {
    static let maximumExistingBindings = 4096

    /// Every existing binding on the same source or target, sorted by binding ID. L1 policy: any
    /// binding already on the target conflicts, even from another source, so the caller must refuse
    /// or replace it; multiple sources coexisting on one target awaits multi-source arbitration.
    static func find(source: ControlSourceID, target: ParameterID,
                     in existing: [ControlBinding]) throws(LearnRefusal) -> [LearnConflict] {
        guard existing.count <= maximumExistingBindings else { throw .tooManyBindings(existing.count) }
        var seen = Set<BindingID>()
        var conflicts: [LearnConflict] = []
        for binding in existing {
            guard seen.insert(binding.id).inserted else { throw .duplicateBinding(binding.id) }
            let kind: LearnConflictKind
            switch (binding.source == source, binding.target == target) {
            case (true, true): kind = .sameSourceAndTarget
            case (true, false): kind = .sameSource
            case (false, true): kind = .sameTarget
            case (false, false): continue
            }
            conflicts.append(LearnConflict(binding: binding.id, kind: kind))
        }
        return conflicts.sorted { $0.binding < $1.binding }
    }

    /// The sorted IDs to remove, or a refusal when the resolution does not match `conflicts`.
    static func resolve(_ resolution: LearnConflictResolution,
                        conflicts: [LearnConflict]) throws(LearnRefusal) -> [BindingID] {
        let current = Set(conflicts.map(\.binding))
        switch resolution {
        case .refuse:
            guard conflicts.isEmpty else { throw .conflicted(conflicts) }
            return []
        case .replace(let named):
            guard named == current else {
                throw .staleReplacement(expected: current.sorted(), found: named.sorted())
            }
            return current.sorted()
        }
    }
}
