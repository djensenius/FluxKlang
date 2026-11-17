import Foundation

/// Proof that the archive at `LegacyMigrationArchive.destination` holds the adopted sources byte for byte. For a new
/// archive it describes the sources just read, which read the same before and after it was verified; for an existing
/// one it describes the archive's own contents, and the live draft names agree with its draft member. Only
/// `LegacyMigrationArchive.archive` mints one.
struct LegacyMigrationReceipt: Sendable, Equatable {
    let report: LegacySourceReport
    /// The adopted sources, in `ProjectMigrationSource` order; each one's original bytes are in the archive.
    let archived: [ProjectMigrationSource]
    /// The sources a later slice may retire, by rename only: at most the pending draft. Home wiring and the USB map
    /// stay the live stores and are never retirable.
    let retirable: [ProjectMigrationSource]

    fileprivate init(report: LegacySourceReport) {
        self.report = report
        var archived: [ProjectMigrationSource] = []
        if case .adopted = report.homeWiring { archived.append(.connections) }
        if case .adopted = report.hostLocal { archived.append(.usbMap) }
        if case .adopted = report.draft { archived.append(.pendingDraft) }
        self.archived = archived
        retirable = archived.filter { $0 == .pendingDraft }
    }
}

/// Copies the adopted legacy files into one verified, local package at the app root, `LegacyMigration.fluxklang`,
/// without changing them. Non-destructive by construction: every mutation goes through the staging primitives to the
/// plan's staging or destination name, the plan is `createNew` (a rename that never replaces), an existing archive is
/// only read, and no legacy name is ever renamed, removed or written. Nothing is retired here; the draft is retired
/// afterwards by `LegacyDraftRetirement`.
///
/// Home wiring and the USB map are evidence only: they remain the live stores. Home wiring is read from the local
/// `studio-connections.json`, which may lag the key-value copy; the archive records that freshness.
enum LegacyMigrationArchive {
    static let destination = "LegacyMigration.fluxklang"
    static let token = "legacy1"
    static let projectPath = LegacyAdoption.projectPath
    static let connectionsPath = LegacySidecarPlan.connectionsPath
    static let draftPath = LegacySidecarPlan.draftPath
    static let usbMapPath = "legacy/LaunchControlXL.json"
    static let recordKey = "legacyMigration"
    static let projectName = "Legacy migration"

    /// The fixed `createNew` plan for the archive.
    static func plan(limits: ProjectPackageLimits) throws(StagingRefusal) -> StagingPlan {
        try StagingPlan.make(destination: destination, token: token, mode: .createNew, limits: limits)
    }

    /// The package for `report`'s adopted sources, or nil when none was adopted. Pure: a project with no graphs whose
    /// extensions hold the inert provenance and the per-source record, plus each adopted original as opaque state.
    static func contents(
        _ report: LegacySourceReport, projectID: ProjectID, policy: ProjectPackageManifestPolicy
    ) throws(LegacyMigrationArchiveRefusal) -> ProjectPackageContents? {
        var files: [ProjectPackageFile] = []
        if case .adopted(let part) = report.homeWiring {
            files.append(ProjectPackageFile(path: connectionsPath, role: .opaqueState, bytes: part.original))
        }
        if case .adopted(let part) = report.hostLocal {
            files.append(ProjectPackageFile(path: usbMapPath, role: .opaqueState, bytes: part.original))
        }
        if case .adopted(let draft) = report.draft {
            files.append(ProjectPackageFile(path: draftPath, role: .opaqueState, bytes: draft.original))
        }
        guard !files.isEmpty else { return nil }
        let project = ProjectDocument(
            id: projectID, name: projectName,
            extensions: [LegacyAdoption.provenanceKey: MigratedDraft.provenance, recordKey: record(report)]
        )
        do {
            return try ProjectPackageContents.make(
                project: (projectPath, project), graphs: [], extraFiles: files, policy: policy
            )
        } catch {
            throw .assembly(error)
        }
    }

    /// Opens `directory` through a no-follow `DiskStagingFileSystem`, runs the core and closes it. A missing directory
    /// is every source missing, as `LegacySourceReader.read(directory:)` reports it, so nothing is archived; one that
    /// cannot be opened otherwise (a link or not a directory) is refused. Either way nothing is written.
    static func archive(
        directory: URL, projectID: ProjectID, policy: ProjectPackageManifestPolicy
    ) -> LegacyMigrationArchiveOutcome {
        var store: DiskStagingFileSystem
        do {
            store = try DiskStagingFileSystem(root: directory, limits: policy.packageLimits)
        } catch {
            let report = LegacySourceReader.read(directory: directory, limits: policy.packageLimits)
            return report == .uniform(nil) ? .nothingToArchive(report) : .refused(.staging(error))
        }
        defer { store.close() }
        return archive(in: &store, projectID: projectID, policy: policy)
    }

    /// The core over a volume whose root is the app directory: recover our own staging name and check the destination.
    /// Without an archive it reads the sources, builds, stages and re-reads a new one, then reads the sources again.
    ///
    /// An existing archive is the commit record (rule A): it is validated on its own plus the two draft names, and
    /// the live Home wiring, the USB map and `projectID` are never read or compared; they are evidence only and may
    /// change after archiving. Its receipt describes the archive's contents, so a draft retired since then is still
    /// retirable and a later `LegacyDraftRetirement.retire` converges.
    static func archive<FS: StagingFileSystem>(
        in store: inout FS, projectID: ProjectID, policy: ProjectPackageManifestPolicy
    ) -> LegacyMigrationArchiveOutcome {
        let limits = policy.packageLimits
        let plan: StagingPlan
        do {
            plan = try self.plan(limits: limits)
        } catch {
            return .refused(.staging(error))
        }
        do {
            _ = try StagingRecovery.recover(plan: plan, in: &store)
        } catch {
            return .refused(.recovery(error))
        }
        do {
            if try store.status(at: plan.destination) != nil { return existing(plan, policy, &store) }
        } catch {
            return .refused(.staging(.ioFailed(step: .preflight, fault: error, cleanup: .notNeeded)))
        }
        let first = LegacySourceReader.read(in: &store, limits: limits)
        guard let created = create(plan, first, projectID, policy, &store) else { return .nothingToArchive(first) }
        let receipt: LegacyMigrationReceipt
        switch created {
        case .success(let minted): receipt = minted
        case .failure(let refusal): return .refused(refusal)
        }
        guard LegacySourceReader.read(in: &store, limits: limits) == first else { return .refused(.sourcesChanged) }
        return .archived(receipt)
    }

    /// An existing archive: validates it as the commit record, then checks only the two draft names against its draft
    /// member (`LegacyDraftRetirement.state`). Pending, retired and no draft archived are `.alreadyArchived`; another
    /// draft at the original name, other content at the retired name or an archived draft gone from both names is
    /// `.archiveDiffers`. Never reads Home wiring or the USB map and never writes.
    private static func existing<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ policy: ProjectPackageManifestPolicy, _ store: inout FS
    ) -> LegacyMigrationArchiveOutcome {
        let report: LegacySourceReport
        switch committed(plan, policy, &store) {
        case .success(let recorded): report = recorded
        case .failure(let refusal): return .refused(refusal)
        }
        let member: Data? = if case .adopted(let draft) = report.draft { draft.original } else { nil }
        switch LegacyDraftRetirement.state(member: member, in: &store, policy: policy) {
        case .failure(let refusal): return .refused(.staging(refusal))
        case .success(.draftChanged), .success(.retiredNameOccupied), .success(.draftGone):
            return .refused(.archiveDiffers)
        case .success(.noDraftArchived), .success(.pending), .success(.retired):
            return .alreadyArchived(LegacyMigrationReceipt(report: report))
        }
    }

    /// Builds the package for `report`, stages it under `plan` and re-reads it; nil when nothing was adopted.
    private static func create<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ report: LegacySourceReport, _ projectID: ProjectID,
        _ policy: ProjectPackageManifestPolicy, _ store: inout FS
    ) -> Result<LegacyMigrationReceipt, LegacyMigrationArchiveRefusal>? {
        let contents: ProjectPackageContents
        do {
            guard let built = try self.contents(report, projectID: projectID, policy: policy) else { return nil }
            contents = built
        } catch {
            return .failure(error)
        }
        do {
            _ = try StagedPackageExport.run(plan: plan, contents: contents, in: &store)
        } catch {
            return .failure(.staging(error))
        }
        if let refusal = mismatch(plan, contents, policy, &store) { return .failure(refusal) }
        return .success(LegacyMigrationReceipt(report: report))
    }

    /// Reads the archive back and compares every member with `contents`; nil when they match. Never writes.
    private static func mismatch<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ contents: ProjectPackageContents, _ policy: ProjectPackageManifestPolicy,
        _ store: inout FS
    ) -> LegacyMigrationArchiveRefusal? {
        let found: ProjectPackageContents
        do {
            found = try readArchive(plan, policy, &store)
        } catch {
            if case .ioFailed = error { return .staging(error) }
            return .archiveDiffers
        }
        guard found.manifestBytes == contents.manifestBytes, found.directories == contents.directories,
              found.files == contents.files else { return .archiveDiffers }
        return nil
    }

    /// Validates an existing archive as the commit record and returns the report it records. It must be a readable
    /// package whose project carries the provenance and the record, whose members are exactly the sources the record
    /// marks adopted, each of which splits again, and which rebuilds byte for byte under its own project ID. Never
    /// writes and reads nothing outside the archive.
    private static func committed<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ policy: ProjectPackageManifestPolicy, _ store: inout FS
    ) -> Result<LegacySourceReport, LegacyMigrationArchiveRefusal> {
        let found: ProjectPackageContents
        do {
            found = try readArchive(plan, policy, &store)
        } catch {
            if case .ioFailed = error { return .failure(.staging(error)) }
            return .failure(.archiveDiffers)
        }
        func member(_ path: String) -> Data? { found.files.first { $0.path == path }?.bytes }
        guard let projectBytes = member(projectPath),
              let project = try? ProjectDocument.decode(from: projectBytes),
              project.extensions?[LegacyAdoption.provenanceKey] == MigratedDraft.provenance,
              case .object(let record)? = project.extensions?[recordKey],
              case .object(let sources)? = record["sources"],
              let report = recordedReport(sources, member: member, limits: policy.packageLimits),
              let rebuilt = try? contents(report, projectID: project.id, policy: policy),
              rebuilt.manifestBytes == found.manifestBytes, rebuilt.directories == found.directories,
              rebuilt.files == found.files else { return .failure(.archiveDiffers) }
        return .success(report)
    }

    private static func readArchive<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ policy: ProjectPackageManifestPolicy, _ store: inout FS
    ) throws(StagingRefusal) -> ProjectPackageContents {
        try StagedPackageImport.read(
            from: plan.destination, policy: policy, chunkByteCount: StagedPackageImport.defaultChunkByteCount,
            in: &store
        )
    }

    // MARK: Record

    /// Each source's outcome, the draft's identity and the Home wiring's freshness. No bytes, paths or OS text.
    private static func record(_ report: LegacySourceReport) -> JSONValue {
        var record: [String: JSONValue] = [
            "sources": .object([
                "connections": state(report.homeWiring), "usbMap": state(report.hostLocal),
                "pendingDraft": state(report.draft)
            ]),
            "homeWiring": .object(["freshness": .string("localFile")])
        ]
        if case .adopted(let draft) = report.draft {
            record["draft"] = .object([
                "id": .string(draft.id.uuidString),
                "createdAt": .double(draft.createdAt.timeIntervalSinceReferenceDate)
            ])
        }
        return .object(record)
    }

    private static func state<Value>(_ outcome: LegacySourceOutcome<Value>) -> JSONValue {
        switch outcome {
        case .adopted: .object(["state": .string("adopted")])
        case .missing: .object(["state": .string("missing")])
        case .refused(let refusal): .object(["state": .string("refused"), "kind": .string(kind(refusal))])
        }
    }

    private static func kind(_ refusal: LegacySourceRefusal) -> String {
        switch refusal {
        case .io(.directoryRefused): "io.directoryRefused"
        case .io(.notRegularFile): "io.notRegularFile"
        case .io(.hardLinked): "io.hardLinked"
        case .io(.otherVolume): "io.otherVolume"
        case .io(.changed): "io.changed"
        case .io(.failed): "io.failed"
        case .migration(let refusal):
            switch refusal.kind {
            case .oversized: "migration.oversized"
            case .undecodable: "migration.undecodable"
            case .unsupportedShape: "migration.unsupportedShape"
            }
        }
    }

    // MARK: Reading the record back

    /// The report an existing archive records: each adopted source split again from its member, each other source as
    /// recorded. Nil when a state is unknown, a member is missing for an adopted source or present for another, or a
    /// member no longer splits. An `io.failed` fault is not recorded, so it reads back as `ioError`.
    private static func recordedReport(
        _ sources: [String: JSONValue], member: (String) -> Data?, limits: ProjectPackageLimits
    ) -> LegacySourceReport? {
        guard let connections = recorded(sources["connections"], .connections, member(connectionsPath)),
              let usbMap = recorded(sources["usbMap"], .usbMap, member(usbMapPath)),
              let draft = recorded(sources["pendingDraft"], .pendingDraft, member(draftPath)) else { return nil }
        let split = ProjectMigration.split(
            connections: connections.bytes, usbMap: usbMap.bytes, draft: draft.bytes, limits: limits
        )
        guard let homeWiring = connections.outcome(split.homeWiring),
              let hostLocal = usbMap.outcome(split.hostLocal),
              let migrated = draft.outcome(split.draft) else { return nil }
        return LegacySourceReport(homeWiring: homeWiring, hostLocal: hostLocal, draft: migrated)
    }

    /// One source's state as the record holds it, with the member's bytes when it was adopted.
    private enum Recorded {
        case adopted(Data), refused(LegacySourceRefusal), missing

        var bytes: Data? {
            if case .adopted(let bytes) = self { return bytes }
            return nil
        }

        /// Nil when an adopted member no longer splits.
        func outcome<Value: Sendable & Equatable>(
            _ split: Result<Value, ProjectMigrationRefusal>?
        ) -> LegacySourceOutcome<Value>? {
            switch (self, split) {
            case (.missing, _): .missing
            case (.refused(let refusal), _): .refused(refusal)
            case (.adopted, .success(let value)?): .adopted(value)
            case (.adopted, _): nil
            }
        }
    }

    /// Nil when the state is unknown or disagrees with whether a member is present.
    private static func recorded(
        _ value: JSONValue?, _ source: ProjectMigrationSource, _ member: Data?
    ) -> Recorded? {
        guard case .object(let fields)? = value, case .string(let state)? = fields["state"] else { return nil }
        switch state {
        case "adopted":
            return member.map { .adopted($0) }
        case "missing":
            return member == nil ? .missing : nil
        case "refused":
            guard member == nil, case .string(let kind)? = fields["kind"],
                  let refusal = refusal(kind, source) else { return nil }
            return .refused(refusal)
        default:
            return nil
        }
    }

    /// The inverse of `kind`.
    private static func refusal(_ kind: String, _ source: ProjectMigrationSource) -> LegacySourceRefusal? {
        switch kind {
        case "io.directoryRefused": .io(.directoryRefused)
        case "io.notRegularFile": .io(.notRegularFile)
        case "io.hardLinked": .io(.hardLinked)
        case "io.otherVolume": .io(.otherVolume)
        case "io.changed": .io(.changed)
        case "io.failed": .io(.failed(.ioError))
        case "migration.oversized": .migration(ProjectMigrationRefusal(source: source, kind: .oversized))
        case "migration.undecodable": .migration(ProjectMigrationRefusal(source: source, kind: .undecodable))
        case "migration.unsupportedShape":
            .migration(ProjectMigrationRefusal(source: source, kind: .unsupportedShape))
        default: nil
        }
    }
}
