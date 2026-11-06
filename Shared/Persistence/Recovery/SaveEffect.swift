/// A value describing work for the caller; the reducer never performs it.
enum SaveEffect: Equatable, Sendable {
    case beginWrite(version: SaveContentVersion, attempt: SaveAttemptID)
    case retainCopy(role: SaveCopyRole, version: SaveContentVersion, label: String)
    case releaseCopy(role: SaveCopyRole, version: SaveContentVersion, label: String)
    case presentConflict(base: SaveContentVersion, local: SaveContentVersion, remote: SaveContentVersion)
    case reportFault(SaveFault)
    case conflictResolutionApplied(choice: SaveConflictChoice, requiresReview: Bool)

    static func ordered(_ effects: [SaveEffect]) -> [SaveEffect] {
        var result: [SaveEffect] = []
        var copyRun: [SaveEffect] = []
        var runRetains: Bool?

        for effect in effects {
            switch effect {
            case .retainCopy:
                if runRetains == false {
                    appendCopyRun(copyRun, retaining: false, to: &result)
                    copyRun.removeAll()
                }
                runRetains = true
                copyRun.append(effect)
            case .releaseCopy:
                if runRetains == true {
                    appendCopyRun(copyRun, retaining: true, to: &result)
                    copyRun.removeAll()
                }
                runRetains = false
                copyRun.append(effect)
            default:
                if let retainGroup = runRetains {
                    appendCopyRun(copyRun, retaining: retainGroup, to: &result)
                    copyRun.removeAll()
                    runRetains = nil
                }
                result.append(effect)
            }
        }
        if let retainGroup = runRetains {
            appendCopyRun(copyRun, retaining: retainGroup, to: &result)
        }
        return result
    }

    private static func appendCopyRun(
        _ effects: [SaveEffect],
        retaining: Bool,
        to result: inout [SaveEffect]
    ) {
        result.append(contentsOf: copyEffects(effects, retain: retaining))
    }

    private static func copyEffectOrder(_ lhs: SaveEffect, _ rhs: SaveEffect) -> Bool {
        guard let left = copyKey(lhs), let right = copyKey(rhs) else { return false }
        if left.role != right.role { return left.role.rawValue < right.role.rawValue }
        if left.version != right.version {
            return left.version.digest.utf8.lexicographicallyPrecedes(right.version.digest.utf8)
        }
        if !left.label.utf8.elementsEqual(right.label.utf8) {
            return left.label.utf8.lexicographicallyPrecedes(right.label.utf8)
        }
        return false
    }

    private static func copyEffects(_ effects: [SaveEffect], retain: Bool) -> [SaveEffect] {
        var seen: Set<CopyEffectKey> = []
        return effects.compactMap { effect -> SaveEffect? in
            switch effect {
            case .retainCopy where retain, .releaseCopy where !retain:
                guard let key = copyKey(effect), seen.insert(key).inserted else { return nil }
                return effect
            default:
                return nil
            }
        }.sorted(by: copyEffectOrder)
    }

    private static func copyKey(_ effect: SaveEffect) -> CopyEffectKey? {
        switch effect {
        case .retainCopy(let role, let version, let label),
             .releaseCopy(let role, let version, let label):
            return CopyEffectKey(role: role, version: version, label: label)
        default:
            return nil
        }
    }
}

private struct CopyEffectKey: Equatable, Hashable {
    let role: SaveCopyRole
    let version: SaveContentVersion
    let label: String
}
