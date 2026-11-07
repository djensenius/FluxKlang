import Foundation

/// Reads a package from a `StagingFileSystem` and stages it beside a destination.
enum StagedPackageImport {
    static let defaultChunkByteCount = 65_536

    /// A bounded, no-follow read of the package at `root`. Mutates nothing.
    static func read<FS: StagingFileSystem>(
        from root: String, policy: ProjectPackageManifestPolicy, chunkByteCount: Int, in store: inout FS
    ) throws(StagingRefusal) -> ProjectPackageContents {
        var walk = try StagingPackageWalk(policy: policy, chunkByteCount: chunkByteCount, step: .readSource)
        return try walk.run(root: root, in: &store)
    }

    /// Pure checks (chunk size, spelling overlap, source path), then the read-only alias check by node identity,
    /// destination pre-flight, the source read, the operation budget, then the same staged promotion as an
    /// export. The source is never mutated.
    static func run<FS: StagingFileSystem>(
        from source: String, plan: StagingPlan, policy: ProjectPackageManifestPolicy,
        chunkByteCount: Int, in store: inout FS
    ) throws(StagingRefusal) -> StagingReceipt {
        guard chunkByteCount >= 1 else { throw .invalidChunkSize }
        guard !plan.overlaps(source) else { throw .overlappingPaths }
        do {
            _ = try ProjectPackagePath(source, limits: policy.packageLimits)
        } catch {
            throw .package(error)
        }
        try StagingAliasCheck.refuseAliases(source: source, plan: plan, in: &store)
        try StagedPackageExport.preflight(plan, in: &store)
        let contents = try read(from: source, policy: policy, chunkByteCount: chunkByteCount, in: &store)
        let ordered = try StagedPackageExport.prepare(plan: plan, contents: contents)
        return try StagedPackageExport.stage(plan: plan, contents: contents, ordered: ordered, in: &store)
    }
}
