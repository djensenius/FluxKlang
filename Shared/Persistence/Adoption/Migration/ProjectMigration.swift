import Foundation

/// The caller's original bytes of one accepted source, labelled with the class they keep. Never a re-encoding:
/// unknown members, spacing and every move with its verification evidence and lifecycle stay byte for byte.
struct ProjectMigrationPart: Equatable, Sendable {
    let source: ProjectMigrationSource
    let original: Data

    var storageClass: StorageClass { source.storageClass }

    fileprivate init(source: ProjectMigrationSource, original: Data) {
        self.source = source
        self.original = original
    }
}

/// One result per source. `nil` means the source was not supplied; it is never a refusal and never an empty part.
/// Each source succeeds or is refused on its own: a refused source never affects the others.
struct ProjectMigrationSplit: Equatable, Sendable {
    /// `studio-connections.json`, class `.homeWiring`: the only part key-value storage may carry.
    let homeWiring: Result<ProjectMigrationPart, ProjectMigrationRefusal>?
    /// `launch-control-xl.json`, class `.hostLocalRoute`: local files only.
    let hostLocal: Result<ProjectMigrationPart, ProjectMigrationRefusal>?
    /// `assistant-pending-studio-draft.json`, class `.draft`, inert: it has lost its authority.
    let draft: Result<MigratedDraft, ProjectMigrationRefusal>?

    fileprivate init(
        homeWiring: Result<ProjectMigrationPart, ProjectMigrationRefusal>?,
        hostLocal: Result<ProjectMigrationPart, ProjectMigrationRefusal>?,
        draft: Result<MigratedDraft, ProjectMigrationRefusal>?
    ) {
        self.homeWiring = homeWiring
        self.hostLocal = hostLocal
        self.draft = draft
    }
}

/// Splits legacy persisted bytes into synced Home wiring, the host-local USB map and an inert migrated draft.
/// Pure value code: it reads no file, store, iCloud or app state, and writes nothing. Each source is checked in
/// this order: its byte count against `min(limits.maxEntryBytes, 4 MiB)` before any decoding, valid UTF-8, one
/// strict JSON value (`ContractCoding`), then the shape its store loads (see `ProjectMigration+Shapes.swift`).
/// The same input always yields an equal split.
enum ProjectMigration {
    static func split(
        connections: Data?, usbMap: Data?, draft: Data?, limits: ProjectPackageLimits
    ) -> ProjectMigrationSplit {
        ProjectMigrationSplit(
            homeWiring: connections.map { part(.connections, data: $0, limits: limits) },
            hostLocal: usbMap.map { part(.usbMap, data: $0, limits: limits) },
            draft: draft.map { MigratedDraft.migrate($0, limits: limits) }
        )
    }

    /// The per-entry byte cap: the package's entry limit, bounded by the 4 MiB document ceiling.
    static func entryLimit(_ limits: ProjectPackageLimits) -> Int {
        min(limits.maxEntryBytes, ProjectGraphLimits.documentBytes)
    }

    /// The top-level members of `data`, refused in order: oversized, not UTF-8 or not strict JSON, not an object.
    static func members(
        of data: Data, source: ProjectMigrationSource, limits: ProjectPackageLimits
    ) throws(ProjectMigrationRefusal) -> [String: JSONValue] {
        guard data.count <= entryLimit(limits) else { throw ProjectMigrationRefusal(source: source, kind: .oversized) }
        // Defence in depth: strict decoding into `JSONValue` refuses invalid UTF-8 too.
        guard String(validating: data, as: UTF8.self) != nil else {
            throw ProjectMigrationRefusal(source: source, kind: .undecodable)
        }
        let value: JSONValue
        do {
            value = try ContractCoding.decode(JSONValue.self, from: data)
        } catch {
            throw ProjectMigrationRefusal(source: source, kind: .undecodable)
        }
        guard case .object(let fields) = value else {
            throw ProjectMigrationRefusal(source: source, kind: .unsupportedShape)
        }
        return fields
    }

    /// The connections or USB map part, carrying `data` itself once its shape is accepted.
    private static func part(
        _ source: ProjectMigrationSource, data: Data, limits: ProjectPackageLimits
    ) -> Result<ProjectMigrationPart, ProjectMigrationRefusal> {
        do {
            let fields = try members(of: data, source: source, limits: limits)
            let accepted = switch source {
            case .connections: isStoreConnections(fields)
            case .usbMap: isUSBMap(fields)
            case .pendingDraft: false  // Only `MigratedDraft.migrate` accepts a draft.
            }
            guard accepted else { return .failure(ProjectMigrationRefusal(source: source, kind: .unsupportedShape)) }
            return .success(ProjectMigrationPart(source: source, original: data))
        } catch {
            return .failure(error)
        }
    }
}
