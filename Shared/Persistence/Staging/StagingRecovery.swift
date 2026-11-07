enum StagingRecoveryOutcome: Sendable, Equatable {
    case noChange
    case restoredPrevious
    case removedBackup
    case removedStaging
}

/// Repairs a volume after a crash or failure mid-run by looking only at the plan's three names.
///
/// | destination | backup | staging | action |
/// |---|---|---|---|
/// | yes | yes | any | remove the backup (the new package was promoted), then any staging |
/// | no | yes | any | rename the backup back to the destination, then remove any staging |
/// | any | no | yes | remove the staging |
///
/// A `createNew` plan never creates the backup name, so recovery for it ignores that name entirely (it is neither
/// looked at, renamed nor removed) and only removes a leftover staging tree.
///
/// Recovery never lists the parent, never promotes a staging tree and never removes a destination. It assumes the
/// destination plus backup state means the promotion completed; a failed parent sync leaves that state too.
enum StagingRecovery {
    static func recover<FS: StagingFileSystem>(
        plan: StagingPlan, in store: inout FS
    ) throws(StagingRefusal) -> [StagingRecoveryOutcome] {
        let staging = try present(plan.stagingPath, &store)
        let destination = try present(plan.destination, &store)
        var backup = false
        if plan.mode == .replaceExisting { backup = try present(plan.backupPath, &store) }
        var outcomes: [StagingRecoveryOutcome] = []
        if backup && destination {
            try remove(plan.backupPath, &store)
            outcomes.append(.removedBackup)
        } else if backup {
            do {
                try store.rename(from: plan.backupPath, to: plan.destination)
            } catch {
                throw .ioFailed(step: .restorePrevious, fault: error, cleanup: .notNeeded)
            }
            outcomes.append(.restoredPrevious)
        }
        if staging {
            try remove(plan.stagingPath, &store)
            outcomes.append(.removedStaging)
        }
        return outcomes.isEmpty ? [.noChange] : outcomes
    }

    private static func present<FS: StagingFileSystem>(
        _ path: String, _ store: inout FS
    ) throws(StagingRefusal) -> Bool {
        do {
            return try store.status(at: path) != nil
        } catch {
            throw .ioFailed(step: .preflight, fault: error, cleanup: .notNeeded)
        }
    }

    private static func remove<FS: StagingFileSystem>(_ path: String, _ store: inout FS) throws(StagingRefusal) {
        do {
            try store.removeTree(at: path)
        } catch {
            throw .ioFailed(step: .cleanup, fault: error, cleanup: .notNeeded)
        }
    }
}
