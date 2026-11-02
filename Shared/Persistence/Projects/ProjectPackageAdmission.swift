/// Value-only accounting for a parent-first package stream; stores names/kinds, never payloads.
/// Declarations and consume counts are caller reports, not proof of actual IO or EOF.
/// Reader confinement, filesystem aliases, and TOCTOU protection remain reader responsibilities.
/// Every refusal preserves the entire value. There is no refund: discard an abandoned import.
struct ProjectPackageAdmission: Sendable, Equatable {
    private struct ActiveFile: Sendable, Equatable {
        let declaredByteCount: Int?
        var byteCount = 0
    }

    private let limits: ProjectPackageLimits
    private var entries: [String: ProjectPackageEntryKind] = [:]
    private var activeFile: ActiveFile?
    private var consumedByteCount = 0

    var entryCount: Int { entries.count }
    var totalBytesRead: Int { consumedByteCount }
    var activeFileBytesRead: Int? { activeFile?.byteCount }

    /// Zero when no file is open. A zero allowance does not prove that the input reached EOF.
    var remainingReadableBytes: Int {
        guard let activeFile else { return 0 }
        let remaining = min(
            limits.maxEntryBytes - activeFile.byteCount,
            limits.maxTotalBytes - consumedByteCount
        )
        if let declared = activeFile.declaredByteCount {
            return min(remaining, declared - activeFile.byteCount)
        }
        return remaining
    }

    init(limits: ProjectPackageLimits) {
        self.limits = limits
    }

    mutating func admit(
        path: String,
        kind: ProjectPackageEntryKind,
        declaredByteCount: Int? = nil
    ) throws(ProjectPackageError) {
        guard activeFile == nil else { throw .fileAlreadyOpen }
        guard kind == .directory || kind == .regularFile else { throw .unsupportedKind }
        guard entries.count < limits.maxEntries else { throw .entryLimitExceeded }
        let name = try ProjectPackagePath(path, limits: limits)
        guard entries[name.value] == nil else { throw .duplicatePath }
        if let parent = name.parent {
            guard let parentKind = entries[parent] else { throw .missingParent }
            guard parentKind == .directory else { throw .parentNotDirectory }
        }
        try validateDeclaration(declaredByteCount, kind: kind)

        entries[name.value] = kind
        if kind == .regularFile {
            activeFile = ActiveFile(declaredByteCount: declaredByteCount)
        }
    }

    mutating func consume(byteCount: Int) throws(ProjectPackageError) {
        guard var file = activeFile else { throw .noOpenFile }
        guard byteCount >= 0 else { throw .negativeByteCount }
        let (entryBytes, entryOverflow) = file.byteCount.addingReportingOverflow(byteCount)
        let (totalBytes, totalOverflow) = consumedByteCount.addingReportingOverflow(byteCount)
        guard !entryOverflow, !totalOverflow else { throw .byteCountOverflow }
        guard entryBytes <= limits.maxEntryBytes else { throw .entryBytesExceeded }
        guard totalBytes <= limits.maxTotalBytes else { throw .totalBytesExceeded }
        if let declared = file.declaredByteCount {
            guard entryBytes <= declared else { throw .declaredBytesExceeded }
        }

        file.byteCount = entryBytes
        activeFile = file
        consumedByteCount = totalBytes
    }

    /// For an undeclared file this is only the caller's completion assertion, not an EOF proof.
    mutating func finishFile() throws(ProjectPackageError) {
        guard let activeFile else { throw .noOpenFile }
        if let declared = activeFile.declaredByteCount {
            guard activeFile.byteCount == declared else { throw .declaredByteCountMismatch }
        }
        self.activeFile = nil
    }

    /// Checks current completeness without sealing the value or granting approval/authority.
    func validateComplete() throws(ProjectPackageError) {
        guard activeFile == nil else { throw .fileAlreadyOpen }
    }

    private func validateDeclaration(
        _ byteCount: Int?, kind: ProjectPackageEntryKind
    ) throws(ProjectPackageError) {
        if kind == .directory {
            guard byteCount == nil else { throw .directoryByteCount }
        } else if let byteCount {
            guard byteCount >= 0 else { throw .negativeByteCount }
            guard byteCount <= limits.maxEntryBytes else { throw .entryBytesExceeded }
            guard byteCount <= limits.maxTotalBytes - consumedByteCount else { throw .totalBytesExceeded }
        }
    }
}
