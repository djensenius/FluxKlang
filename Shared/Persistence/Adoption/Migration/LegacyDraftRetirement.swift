import Foundation

/// Takes the authority from the archived legacy pending draft by renaming it, never by deleting it (#122). The
/// draft keeps its data at `retiredName`, a name `PendingStudioPatchStore` does not read, and its original bytes stay
/// in the archive.
///
/// Retirement is one non-replacing rename at the app root followed by a root sync. It retires only a draft the
/// receipt marks retirable and whose live bytes equal the archive's draft member, re-reads the live draft just before
/// the rename and the retired file after it. A crash leaves the draft at one of the two names, so while draft writers
/// are excluded a later run converges on `.retired` or `.alreadyRetired`. After `.draftReplacedDuringRetirement` the
/// writer's file is not the archived draft (unless it saved the same bytes), so later runs refuse without writing:
/// `.draftChanged` while it is at the original name, `.retiredNameOccupied` while it is at the retired name. Home
/// wiring and the USB map are never touched.
///
/// Precondition: the caller excludes draft writers for the whole call, so no `PendingStudioPatchStore` save runs
/// while it does; the launch caller must run it once per process, before the stores load. A file system has no atomic
/// compare-and-rename, so the re-read cannot stop a save that replaces the draft between it and the rename. When the
/// retired file then reads back as another file, the retirement renames that file back without replacing
/// (`.draftReplacedDuringRetirement`). That is a recovery, not a guarantee.
enum LegacyDraftRetirement {
    static let originalName = "assistant-pending-studio-draft.json"
    static let retiredName = "assistant-pending-studio-draft.retired-legacy1.json"

    /// The launch state for the archive's draft `member` and the two draft names. Pure. Once the archived draft is at
    /// the retired name it is retired, whatever is at the original name: a later draft there is the user's and is left
    /// alone, even with the same bytes. Any other file at the retired name is `.retiredNameOccupied`, including a user
    /// draft a retirement moved there and could not rename back (`LegacyDraftRollback`); it is left in place.
    static func launchState(
        member: Data?, original: LegacyDraftNode, retired: LegacyDraftNode
    ) -> LegacyDraftLaunchState {
        guard let member else { return .noDraftArchived }
        switch (retired, original) {
        case (.file(member), _): return .retired
        case (.file, _), (.unusable, _): return .retiredNameOccupied
        case (.absent, .file(member)): return .pending
        case (.absent, .absent): return .draftGone
        case (.absent, .file), (.absent, .unusable): return .draftChanged
        }
    }

    /// Opens `directory` through a no-follow `DiskStagingFileSystem`, runs the core and closes it. Draft writers must
    /// be excluded for the whole call.
    static func retire(
        _ receipt: LegacyMigrationReceipt, directory: URL, policy: ProjectPackageManifestPolicy
    ) -> LegacyDraftRetirementOutcome {
        guard receipt.retirable.contains(.pendingDraft) else { return .nothingRetirable }
        var store: DiskStagingFileSystem
        do {
            store = try DiskStagingFileSystem(root: directory, limits: policy.packageLimits)
        } catch {
            return .refused(.staging(error))
        }
        defer { store.close() }
        return retire(receipt, in: &store, policy: policy)
    }

    /// The core over a volume whose root is the app directory. Without a retirable draft in `receipt` it does no IO.
    /// Draft writers must be excluded for the whole call.
    static func retire<FS: StagingFileSystem>(
        _ receipt: LegacyMigrationReceipt, in store: inout FS, policy: ProjectPackageManifestPolicy
    ) -> LegacyDraftRetirementOutcome {
        guard receipt.retirable.contains(.pendingDraft) else { return .nothingRetirable }
        let found: Found
        switch look(&store, policy: policy) {
        case .success(let looked): found = looked
        case .failure(let refusal): return .refused(refusal)
        }
        if let member = found.member, case .adopted(let draft) = receipt.report.draft, member != draft.original {
            return .refused(.receiptMismatch)
        }
        switch launchState(
            member: found.member, original: node(found.names.original), retired: node(found.names.retired)
        ) {
        case .noDraftArchived, .draftGone: return .nothingRetirable
        case .retired: return .alreadyRetired
        case .draftChanged: return .refused(.draftChanged)
        case .retiredNameOccupied: return .refused(.retiredNameOccupied)
        case .pending: break
        }
        guard case .success(let first)? = found.names.original else { return .refused(.draftChanged) }
        return rename(first, found.names, &store)
    }

    /// The launch state of the two draft names against an archive's draft `member`, read with the reader's checks.
    /// Without a member it does no IO. Never writes and never reads Home wiring, the USB map or the archive.
    static func state<FS: StagingFileSystem>(
        member: Data?, in store: inout FS, policy: ProjectPackageManifestPolicy
    ) -> Result<LegacyDraftLaunchState, StagingRefusal> {
        guard let member else { return .success(.noDraftArchived) }
        return names(&store, policy: policy).map {
            launchState(member: member, original: node($0.original), retired: node($0.retired))
        }
    }

    // MARK: Steps

    private typealias Checked = Result<(status: StagingNodeStatus, bytes: Data), LegacySourceRefusal>?

    /// What one look at the two draft names found.
    private struct Names {
        let rootVolume: Int
        let limit: Int
        let original: Checked
        let retired: Checked
    }

    /// What one look at the volume found: the archive's draft member and both draft names.
    private struct Found {
        let member: Data?
        let names: Names
    }

    /// Reads the archive's draft member, then both draft names. Never writes.
    private static func look<FS: StagingFileSystem>(
        _ store: inout FS, policy: ProjectPackageManifestPolicy
    ) -> Result<Found, LegacyDraftRetirementRefusal> {
        let member: Data?
        do {
            let archive = try StagedPackageImport.read(
                from: LegacyMigrationArchive.destination, policy: policy,
                chunkByteCount: StagedPackageImport.defaultChunkByteCount, in: &store
            )
            member = archive.files.first { $0.path == LegacyMigrationArchive.draftPath }?.bytes
        } catch {
            if case .ioFailed = error { return .failure(.staging(error)) }
            return .failure(.archiveUnreadable)
        }
        return names(&store, policy: policy).map { Found(member: member, names: $0) }.mapError { .staging($0) }
    }

    /// Reads the root, then both draft names with the reader's checks. Never writes.
    private static func names<FS: StagingFileSystem>(
        _ store: inout FS, policy: ProjectPackageManifestPolicy
    ) -> Result<Names, StagingRefusal> {
        let rootVolume: Int
        do {
            guard let root = try store.status(at: ""), root.kind == .directory else {
                return .failure(.destinationRefused)
            }
            rootVolume = root.volume
        } catch {
            return .failure(.ioFailed(step: .preflight, fault: error, cleanup: .notNeeded))
        }
        let limit = ProjectMigration.entryLimit(policy.packageLimits)
        let original = check(originalName, rootVolume, limit, &store)
        let retired = check(retiredName, rootVolume, limit, &store)
        // The retired name decides: a fault at the original name matters only while nothing is at the retired name.
        if let fault = fault(retired) ?? (retired == nil ? fault(original) : nil) {
            return .failure(.ioFailed(step: .readSource, fault: fault, cleanup: .notNeeded))
        }
        return .success(Names(rootVolume: rootVolume, limit: limit, original: original, retired: retired))
    }

    /// Re-reads the draft, renames it without replacing, syncs the root and reads the retired file back. A read-back
    /// that fails leaves the state unknown and writes nothing more; one that shows another file is rolled back.
    private static func rename<FS: StagingFileSystem>(
        _ first: (status: StagingNodeStatus, bytes: Data), _ found: Names, _ store: inout FS
    ) -> LegacyDraftRetirementOutcome {
        guard case .success(let again)? = check(originalName, found.rootVolume, found.limit, &store),
              again.status == first.status, again.bytes == first.bytes else { return .refused(.draftChanged) }
        do {
            try store.rename(from: originalName, to: retiredName)
        } catch .exists {
            return .refused(.retiredNameOccupied)
        } catch {
            return .refused(.staging(.ioFailed(step: .promote, fault: error, cleanup: .notNeeded)))
        }
        do {
            try store.syncDirectory(at: "")
        } catch {
            return .refused(.staging(.ioFailed(step: .syncParent, fault: error, cleanup: .notNeeded)))
        }
        guard case .success(let moved)? = check(retiredName, found.rootVolume, found.limit, &store) else {
            return .refused(.staging(.verificationFailed(cleanup: .notNeeded)))
        }
        guard moved.bytes == first.bytes, moved.status.identity == first.status.identity,
              moved.status.volume == first.status.volume else {
            return .refused(.draftReplacedDuringRetirement(rollBack(&store)))
        }
        return .retired
    }

    /// Renames the moved file back to the original name without replacing, then syncs the root. Never deletes: a
    /// newer file at the original name keeps it and the moved file stays at the retired name.
    private static func rollBack<FS: StagingFileSystem>(_ store: inout FS) -> LegacyDraftRollback {
        do {
            try store.rename(from: retiredName, to: originalName)
        } catch .exists {
            return .originalNameOccupied
        } catch {
            return .restoreFailed(.restorePrevious)
        }
        do {
            try store.syncDirectory(at: "")
        } catch {
            return .restoreFailed(.syncParent)
        }
        return .restored
    }

    private static func check<FS: StagingFileSystem>(
        _ name: String, _ rootVolume: Int, _ limit: Int, _ store: inout FS
    ) -> Checked {
        LegacySourceReader.checkedFile(name, source: .pendingDraft, rootVolume: rootVolume, limit: limit, &store)
    }

    private static func node(_ checked: Checked) -> LegacyDraftNode {
        switch checked {
        case nil: .absent
        case .success(let file)?: .file(file.bytes)
        case .failure?: .unusable
        }
    }

    /// A primitive's own failure, which is not a verdict on the node.
    private static func fault(_ checked: Checked) -> StagingIOFault? {
        guard case .failure(.io(.failed(let fault)))? = checked else { return nil }
        return fault
    }
}
