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

struct SaveCopyLabel: Hashable, Sendable, ExpressibleByStringLiteral, Comparable {
    private let value: String

    var stringValue: String { value }

    init(_ value: String) {
        self.value = value
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    static func == (lhs: SaveCopyLabel, rhs: SaveCopyLabel) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value.utf8.count)
        for byte in value.utf8 {
            hasher.combine(byte)
        }
    }

    static func < (lhs: SaveCopyLabel, rhs: SaveCopyLabel) -> Bool {
        lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
    }
}

/// Produces bounded, stable labels for caller-owned copies.
enum SaveConflictLabels {
    static func make(
        _ purpose: String,
        role: SaveCopyRole,
        version: SaveContentVersion
    ) -> SaveCopyLabel {
        SaveCopyLabel("\(purpose)-\(role.name)-\(version.digest)")
    }
}
