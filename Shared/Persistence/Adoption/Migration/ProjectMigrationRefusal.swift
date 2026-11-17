/// The three legacy files a project migration splits. Identity is the case, never a file name.
enum ProjectMigrationSource: Sendable, CaseIterable, Equatable {
    /// `studio-connections.json`: Home wiring and temporary moves.
    case connections
    /// `launch-control-xl.json`: the host-local USB controller map.
    case usbMap
    /// `assistant-pending-studio-draft.json`.
    case pendingDraft

    /// The class each source's bytes keep after the split, matching `StorageInventory`.
    var storageClass: StorageClass {
        switch self {
        case .connections: .homeWiring
        case .usbMap: .hostLocalRoute
        case .pendingDraft: .draft
        }
    }
}

/// Why one source was refused. Each source is checked in this order and stops at the first defect.
enum ProjectMigrationRefusalKind: Sendable, Equatable {
    /// Over `min(maxEntryBytes, 4 MiB)`; checked before any decoding.
    case oversized
    /// Not valid UTF-8, or not one strict JSON value (`ContractCoding`): empty, BOM, NUL, malformed JSON or
    /// duplicate member names.
    case undecodable
    /// Valid JSON that is not the shape the source's store loads.
    case unsupportedShape
}

/// A refused source. Carries no bytes, paths, values or Foundation text: only which source and why.
struct ProjectMigrationRefusal: Error, Equatable, Sendable {
    let source: ProjectMigrationSource
    let kind: ProjectMigrationRefusalKind
}
