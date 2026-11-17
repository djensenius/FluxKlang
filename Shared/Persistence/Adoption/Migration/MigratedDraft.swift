import Foundation

/// A legacy pending studio draft after migration: inert data that has lost its authority (#122).
///
/// It keeps the caller's original bytes, never re-encoded and never stripped (its references stay inside them),
/// plus the decoded `id` and `createdAt`, and carries `provenance`: authority invalidated, review required.
/// It is not a `StudioPatchDraft`, is not `Decodable`, and nothing turns it back into one or hands it to
/// `PendingStudioPatchStore`. Only `migrate` mints one.
struct MigratedDraft: Equatable, Sendable {
    /// The same inert marker as `LegacyAdoption.provenance`, naming this source.
    static let provenance: JSONValue = .object([
        "source": .string("PendingStudioDraft"), "authority": .string("invalidated"), "reviewRequired": .bool(true)
    ])

    let original: Data
    let id: UUID
    let createdAt: Date

    var provenance: JSONValue { Self.provenance }
    var storageClass: StorageClass { ProjectMigrationSource.pendingDraft.storageClass }

    private init(original: Data, id: UUID, createdAt: Date) {
        self.original = original
        self.id = id
        self.createdAt = createdAt
    }

    /// Accepts the members `StudioPatchDraft` requires: a UUID string `id`, a numeric `createdAt` (seconds since
    /// the reference date, `JSONDecoder`'s default date strategy, which `PendingStudioPatchStore` uses), and
    /// `request` and `fragment` objects. Their contents and every optional member are not interpreted.
    static func migrate(
        _ data: Data, limits: ProjectPackageLimits
    ) -> Result<MigratedDraft, ProjectMigrationRefusal> {
        let fields: [String: JSONValue]
        do {
            fields = try ProjectMigration.members(of: data, source: .pendingDraft, limits: limits)
        } catch {
            return .failure(error)
        }
        guard case .string(let rawID)? = fields["id"], let id = UUID(uuidString: rawID),
              let seconds = fields["createdAt"].flatMap(secondsValue),
              case .object? = fields["request"], case .object? = fields["fragment"] else {
            return .failure(ProjectMigrationRefusal(source: .pendingDraft, kind: .unsupportedShape))
        }
        return .success(MigratedDraft(
            original: data, id: id, createdAt: Date(timeIntervalSinceReferenceDate: seconds)
        ))
    }

    private static func secondsValue(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let number): Double(number)
        case .uint(let number): Double(number)
        case .double(let number): number.isFinite ? number : nil
        case .null, .bool, .string, .array, .object: nil
        }
    }
}
