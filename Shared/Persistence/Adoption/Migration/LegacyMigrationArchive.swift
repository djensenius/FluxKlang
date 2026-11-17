import Foundation

/// Proof that the archive at `LegacyMigrationArchive.destination` holds every adopted source byte for byte and that
/// the sources read the same after it was verified. Only `LegacyMigrationArchive.archive` mints one.
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
/// only read, and no legacy name is ever renamed, removed or written. Nothing is retired here.
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

    /// The core over a volume whose root is the app directory: recover our own staging name, read the sources, build
    /// the package, compare with or stage the archive, re-read it, then read the sources again.
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
        let first = LegacySourceReader.read(in: &store, limits: limits)
        let contents: ProjectPackageContents
        do {
            guard let built = try self.contents(first, projectID: projectID, policy: policy) else {
                return .nothingToArchive(first)
            }
            contents = built
        } catch {
            return .refused(error)
        }
        let existed: Bool
        do {
            existed = try store.status(at: plan.destination) != nil
        } catch {
            return .refused(.staging(.ioFailed(step: .preflight, fault: error, cleanup: .notNeeded)))
        }
        if !existed {
            do {
                _ = try StagedPackageExport.run(plan: plan, contents: contents, in: &store)
            } catch {
                return .refused(.staging(error))
            }
        }
        if let refusal = mismatch(plan, contents, policy, &store) { return .refused(refusal) }
        guard LegacySourceReader.read(in: &store, limits: limits) == first else { return .refused(.sourcesChanged) }
        let receipt = LegacyMigrationReceipt(report: first)
        return existed ? .alreadyArchived(receipt) : .archived(receipt)
    }

    /// Reads the archive back and compares every member with `contents`; nil when they match. Never writes.
    private static func mismatch<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ contents: ProjectPackageContents, _ policy: ProjectPackageManifestPolicy,
        _ store: inout FS
    ) -> LegacyMigrationArchiveRefusal? {
        let found: ProjectPackageContents
        do {
            found = try StagedPackageImport.read(
                from: plan.destination, policy: policy, chunkByteCount: StagedPackageImport.defaultChunkByteCount,
                in: &store
            )
        } catch {
            if case .ioFailed = error { return .staging(error) }
            return .archiveDiffers
        }
        guard found.manifestBytes == contents.manifestBytes, found.directories == contents.directories,
              found.files == contents.files else { return .archiveDiffers }
        return nil
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
}
