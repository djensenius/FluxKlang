/// The side of a conflict represented by a retained content version.
enum SaveCopyRole: Int, CaseIterable, Equatable, Hashable, Sendable {
    case local
    case remote

    fileprivate var name: String {
        switch self {
        case .local: return "local"
        case .remote: return "remote"
        }
    }
}

/// The explicit choice required to leave a conflicted save state.
enum SaveConflictChoice: Equatable, Sendable {
    case keepLocal
    case keepRemote
    case keepBoth
}

/// Produces bounded, stable labels for caller-owned copies.
enum SaveConflictLabels {
    static func make(_ purpose: String, role: SaveCopyRole, version: SaveContentVersion) -> String {
        "\(purpose)-\(role.name)-\(version.digest)"
    }
}
