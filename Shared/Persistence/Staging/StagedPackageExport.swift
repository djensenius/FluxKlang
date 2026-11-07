import Foundation

struct StagingReceipt: Sendable, Equatable {
    let mode: StagingMode
    /// True when the old package could not be removed after a successful replace; recovery removes it later.
    let backupRetained: Bool
}

/// Writes a package beside its destination, verifies it by re-reading, then promotes it with renames.
///
/// Nothing here is a file coordinator and promotion is not atomic across processes. A replace has a window
/// (old package renamed away, new one not yet in place) in which the destination is absent; `StagingRecovery`
/// restores the old package from the backup name after a crash in that window.
enum StagedPackageExport {
    /// Pure checks, then pre-flight reads, then the staged write, verification and promotion.
    static func run<FS: StagingFileSystem>(
        plan: StagingPlan, contents: ProjectPackageContents, in store: inout FS
    ) throws(StagingRefusal) -> StagingReceipt {
        let ordered = try prepare(plan: plan, contents: contents)
        try preflight(plan, in: &store)
        return try stage(plan: plan, contents: contents, ordered: ordered, in: &store)
    }

    /// The operation budget, then one P1 pass under the contents' own limits. Returns entries in UTF-8 byte order.
    static func prepare(
        plan: StagingPlan, contents: ProjectPackageContents
    ) throws(StagingRefusal) -> [ProjectPackageEntry] {
        try plan.admitOperations(directories: contents.directories.count, files: contents.files.count)
        do {
            return try ProjectPackageContents.admit(
                manifestBytes: contents.manifestBytes, entries: contents.entries,
                declared: contents.manifest.declaredMemberByteCounts, limits: contents.limits
            )
        } catch {
            throw StagingRefusal.wrapping(error)
        }
    }

    /// Reads the parent, destination, staging and backup names, in that order, and mutates nothing.
    static func preflight<FS: StagingFileSystem>(_ plan: StagingPlan, in store: inout FS) throws(StagingRefusal) {
        let parent = try status(plan.parentPath, &store)
        let destination = try status(plan.destination, &store)
        let staging = try status(plan.stagingPath, &store)
        let backup = try status(plan.backupPath, &store)
        guard let parent, parent.kind == .directory else { throw .packageIO(.destinationParentRefused) }
        try checkDestination(plan.mode, destination, parent: parent)
        guard staging == nil, backup == nil else { throw .stagingNameInUse }
    }

    static func stage<FS: StagingFileSystem>(
        plan: StagingPlan, contents: ProjectPackageContents, ordered: [ProjectPackageEntry], in store: inout FS
    ) throws(StagingRefusal) -> StagingReceipt {
        do {
            try write(plan, contents, ordered, &store)
            try verify(plan, contents, &store)
            try promote(plan, &store)
            return try finish(plan, &store)
        } catch {
            throw settle(error, plan, &store)
        }
    }

    private static func checkDestination(
        _ mode: StagingMode, _ destination: StagingNodeStatus?, parent: StagingNodeStatus
    ) throws(StagingRefusal) {
        switch mode {
        case .createNew:
            guard destination == nil else { throw .destinationExists }
        case .replaceExisting:
            guard let destination else { throw .destinationMissing }
            switch destination.kind {
            case .directory:
                guard destination.volume == parent.volume else { throw .packageIO(.crossedMountPoint) }
            case .regularFile: throw .destinationNotDirectory
            case .symbolicLink, .unsupported: throw .destinationRefused
            }
        }
    }

    // MARK: Write

    private static func write<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ contents: ProjectPackageContents, _ ordered: [ProjectPackageEntry], _ store: inout FS
    ) throws(StagingRefusal) {
        let staging = plan.stagingPath
        do { try store.makeDirectory(at: staging) } catch { throw fail(.createStagingRoot, error) }
        let manifest = StagingPlan.join(staging, ProjectPackageManifest.manifestMemberPath)
        do {
            try store.createFile(at: manifest, bytes: contents.manifestBytes)
        } catch {
            throw fail(.writeManifest, error)
        }
        for entry in ordered {
            let path = StagingPlan.join(staging, entry.path)
            do {
                if let bytes = entry.bytes {
                    try store.createFile(at: path, bytes: bytes)
                } else {
                    try store.makeDirectory(at: path)
                }
            } catch {
                throw fail(.writeEntry, error)
            }
        }
        for entry in ordered.reversed() where entry.bytes == nil {
            do {
                try store.syncDirectory(at: StagingPlan.join(staging, entry.path))
            } catch {
                throw fail(.syncStaging, error)
            }
        }
        do { try store.syncDirectory(at: staging) } catch { throw fail(.syncStaging, error) }
    }

    // MARK: Verify

    private static func verify<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ contents: ProjectPackageContents, _ store: inout FS
    ) throws(StagingRefusal) {
        let policy: ProjectPackageManifestPolicy
        do {
            policy = try ProjectPackageManifestPolicy(
                packageLimits: contents.limits, maxManifestBytes: contents.limits.maxEntryBytes
            )
        } catch {
            throw .package(error)
        }
        var walk = try StagingPackageWalk(
            policy: policy, chunkByteCount: StagedPackageImport.defaultChunkByteCount, step: .verifyReread
        )
        let reread: ProjectPackageContents
        do {
            reread = try walk.run(root: plan.stagingPath, in: &store)
        } catch {
            if case .ioFailed = error { throw error }
            throw .verificationFailed(cleanup: .notNeeded)
        }
        guard reread.manifestBytes == contents.manifestBytes, reread.directories == contents.directories,
              reread.files == contents.files else { throw .verificationFailed(cleanup: .notNeeded) }
    }

    // MARK: Promote

    private static func promote<FS: StagingFileSystem>(_ plan: StagingPlan, _ store: inout FS) throws(StagingRefusal) {
        switch plan.mode {
        case .createNew:
            do { try store.rename(from: plan.stagingPath, to: plan.destination) } catch { throw fail(.promote, error) }
        case .replaceExisting:
            do {
                try store.rename(from: plan.destination, to: plan.backupPath)
            } catch {
                throw fail(.retireExisting, error)
            }
            do {
                try store.rename(from: plan.stagingPath, to: plan.destination)
            } catch {
                throw rollBack(after: error, plan, &store)
            }
        }
    }

    private static func rollBack<FS: StagingFileSystem>(
        after fault: StagingIOFault, _ plan: StagingPlan, _ store: inout FS
    ) -> StagingRefusal {
        guard fault != .interrupted else { return fail(.promote, fault) }
        do {
            try store.rename(from: plan.backupPath, to: plan.destination)
            return .promotionFailed(fault: fault, rolledBack: true, cleanup: .notNeeded)
        } catch {
            return .promotionFailed(fault: fault, rolledBack: false, cleanup: .notNeeded)
        }
    }

    private static func finish<FS: StagingFileSystem>(
        _ plan: StagingPlan, _ store: inout FS
    ) throws(StagingRefusal) -> StagingReceipt {
        do { try store.syncDirectory(at: plan.parentPath) } catch { throw fail(.syncParent, error) }
        guard plan.mode == .replaceExisting else { return StagingReceipt(mode: plan.mode, backupRetained: false) }
        do {
            try store.removeTree(at: plan.backupPath)
            return StagingReceipt(mode: plan.mode, backupRetained: false)
        } catch {
            if error == .interrupted { throw fail(.retireBackup, error) }
            return StagingReceipt(mode: plan.mode, backupRetained: true)
        }
    }

    // MARK: Failure handling

    /// Attaches the cleanup result: an interruption is never cleaned up, a rollback that failed leaves everything.
    private static func settle<FS: StagingFileSystem>(
        _ refusal: StagingRefusal, _ plan: StagingPlan, _ store: inout FS
    ) -> StagingRefusal {
        switch refusal {
        case let .ioFailed(step, fault, _):
            let stages: [StagingStep] = [
                .writeManifest, .writeEntry, .syncStaging, .verifyReread, .retireExisting, .promote
            ]
            let cleanup: StagingCleanup = fault == .interrupted
                ? .notAttempted : stages.contains(step) ? removeStaging(plan, &store) : .notNeeded
            return .ioFailed(step: step, fault: fault, cleanup: cleanup)
        case .verificationFailed:
            return .verificationFailed(cleanup: removeStaging(plan, &store))
        case let .promotionFailed(fault, rolledBack, _):
            let cleanup: StagingCleanup = rolledBack ? removeStaging(plan, &store) : .notAttempted
            return .promotionFailed(fault: fault, rolledBack: rolledBack, cleanup: cleanup)
        default:
            // Only the three failures above are thrown after staging begins.
            return refusal
        }
    }

    private static func removeStaging<FS: StagingFileSystem>(_ plan: StagingPlan, _ store: inout FS) -> StagingCleanup {
        do {
            try store.removeTree(at: plan.stagingPath)
            return .removed
        } catch {
            return .leftBehind
        }
    }

    private static func fail(_ step: StagingStep, _ fault: StagingIOFault) -> StagingRefusal {
        .ioFailed(step: step, fault: fault, cleanup: .notNeeded)
    }

    private static func status<FS: StagingFileSystem>(
        _ path: String, _ store: inout FS
    ) throws(StagingRefusal) -> StagingNodeStatus? {
        do { return try store.status(at: path) } catch { throw fail(.preflight, error) }
    }
}
