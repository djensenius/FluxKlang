import Foundation

/// Opens a package for inspection only: one bounded `ProjectPackageReader` pass under an explicit
/// admission policy, then `ProjectPackageDocuments` decoding, then diagnostics. It writes nothing and
/// resolves, migrates or activates nothing; every failure becomes a text-free refusal.
struct ProjectPackageInspectionLoader: Sendable {
    static let maxEntries = 4_096
    static let maxDepth = 16
    static let maxPathUTF8Bytes = 1_024
    static let maxMemberBytes = 8_388_608
    static let maxTotalBytes = 33_554_432
    static let maxManifestBytes = 1_048_576
    static let chunkByteCount = 65_536

    /// The reviewed admission policy, built from the constants above.
    static func admissionPolicy() throws(ProjectPackageError) -> ProjectPackageManifestPolicy {
        try ProjectPackageManifestPolicy(
            packageLimits: ProjectPackageLimits(
                maxEntries: maxEntries, maxDepth: maxDepth, maxPathUTF8Bytes: maxPathUTF8Bytes,
                maxEntryBytes: maxMemberBytes, maxTotalBytes: maxTotalBytes
            ),
            maxManifestBytes: maxManifestBytes
        )
    }

    /// Nil selects `admissionPolicy()`; tests inject smaller limits.
    let policy: ProjectPackageManifestPolicy?
    /// Forwarded to the reader's chunk hook; nil in production.
    var chunkHookForTesting: (@Sendable (String, Int) -> Void)?

    init(policy: ProjectPackageManifestPolicy? = nil) {
        self.policy = policy
    }

    /// Reads, decodes and diagnoses synchronously on the calling thread.
    func inspect(at root: URL) throws(ProjectPackageInspectionRefusal) -> ProjectPackageInspection {
        let contents: ProjectPackageContents
        do {
            var reader = try ProjectPackageReader(
                policy: policy ?? Self.admissionPolicy(), chunkByteCount: Self.chunkByteCount
            )
            reader.chunkHookForTesting = chunkHookForTesting
            contents = try reader.read(from: root)
        } catch {
            throw ProjectPackageInspectionRefusal(error)
        }
        let documents: ProjectPackageDocuments
        do {
            documents = try ProjectPackageDocuments(contents: contents)
        } catch {
            throw ProjectPackageInspectionRefusal(error)
        }
        return ProjectPackageInspection(documents: documents)
    }

    /// Runs `inspect(at:)` off the caller's actor: without `NonisolatedNonsendingByDefault`, a nonisolated
    /// async function runs on the global concurrent executor. A started read is never abandoned;
    /// cancellation is checked only after it finishes, and then yields `.cancelled`, never the payload.
    nonisolated func load(at root: URL) async throws(ProjectPackageInspectionRefusal) -> ProjectPackageInspection {
        let outcome = Result { () throws(ProjectPackageInspectionRefusal) in try inspect(at: root) }
        guard !Task.isCancelled else { throw .cancelled }
        return try outcome.get()
    }
}
