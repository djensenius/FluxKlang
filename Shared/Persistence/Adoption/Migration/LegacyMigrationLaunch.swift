/// Evidence from one validated archive read and a subsequent look at the two draft names. This is not an atomic
/// multi-file snapshot or a pin on the archive pathname: later replacements do not change this retained report.
struct LegacyMigrationObservation: Sendable, Equatable {
    let report: LegacySourceReport
    let launch: LegacyDraftLaunchState
    /// Nil for conflicting draft names, even though their validated archived draft can still be reviewed.
    let receipt: LegacyMigrationReceipt?

    var review: ArchivedDraftReview? {
        guard case .adopted(let draft) = report.draft else { return nil }
        return ArchivedDraftReview.make(draft: draft, launch: launch)
    }
}

/// Payload-free failures; no raw filesystem errors or production paths are presented.
enum LegacyMigrationLaunchRefusal: Error, Sendable, Equatable {
    case invalidArchive
    case readFailed(StagingRefusal)
}

enum LegacyMigrationLaunchOutcome: Sendable, Equatable {
    case missingArchive
    case observed(LegacyMigrationObservation)
    case refused(LegacyMigrationLaunchRefusal)
}

/// Read-only observation prerequisite, not launch orchestration. No archive creation, staging recovery, retirement,
/// authoritative loading or writer admission. The production PendingStudioPatchStore exclusion is not wired.
enum LegacyMigrationLaunch {
    /// The caller must exclude draft writers for a stable classification; `inout` does not exclude production
    /// writers. Even then this is evidence about the archive read, not whole-operation archive-version pinning.
    /// Real writer exclusion, retirement failure handling and the authorized loader handoff remain integration work.
    static func observe<FS: StagingFileSystem>(
        in store: inout FS, policy: ProjectPackageManifestPolicy
    ) -> LegacyMigrationLaunchOutcome {
        let plan: StagingPlan
        do {
            plan = try LegacyMigrationArchive.plan(limits: policy.packageLimits)
        } catch {
            return .refused(.readFailed(error))
        }
        do {
            guard try store.status(at: plan.destination) != nil else { return .missingArchive }
        } catch {
            return .refused(.readFailed(.ioFailed(step: .preflight, fault: error, cleanup: .notNeeded)))
        }
        switch LegacyMigrationArchive.observation(plan, policy, &store) {
        case .success(let observed): return .observed(observed)
        case .failure(let refusal): return .refused(refusal)
        }
    }
}
