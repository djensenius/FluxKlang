enum StagingMode: Sendable, Equatable {
    case createNew
    case replaceExisting
}

/// A staging plan validated at construction: the destination, its hidden sibling staging and backup
/// names, the package limits, and the mutating-operation ceiling. Only `make` can construct one.
struct StagingPlan: Sendable, Equatable {
    static let maximumOperations = 100_000
    static let tokenByteRange = 1...32

    let destination: String
    let parentPath: String
    let stagingPath: String
    let backupPath: String
    let mode: StagingMode
    let limits: ProjectPackageLimits
    let operationCeiling: Int

    private init(
        destination: ProjectPackagePath, siblings: (staging: String, backup: String),
        mode: StagingMode, limits: ProjectPackageLimits, ceiling: Int
    ) {
        self.destination = destination.value
        parentPath = destination.parent ?? ""
        stagingPath = siblings.staging
        backupPath = siblings.backup
        self.mode = mode
        self.limits = limits
        operationCeiling = ceiling
    }

    /// `token` is 1...32 bytes of `[a-z0-9]`. The staging and backup names are `.<leaf>.staging-<token>` and
    /// `.<leaf>.previous-<token>` beside the destination, so the three names are distinct siblings by construction.
    static func make(
        destination: String, token: String, mode: StagingMode, limits: ProjectPackageLimits,
        operationCeiling: Int = maximumOperations
    ) throws(StagingRefusal) -> StagingPlan {
        guard (1...maximumOperations).contains(operationCeiling) else { throw .invalidOperationCeiling }
        guard tokenByteRange.contains(token.utf8.count),
              token.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) })
        else { throw .invalidToken }
        let path = try admitted(destination, limits: limits)
        let parent = path.parent.map { $0 + "/" } ?? ""
        let leaf = String(path.value.unicodeScalars.dropFirst(parent.unicodeScalars.count))
        let staging = try admitted(parent + "." + leaf + ".staging-" + token, limits: limits)
        let backup = try admitted(parent + "." + leaf + ".previous-" + token, limits: limits)
        return StagingPlan(
            destination: path, siblings: (staging.value, backup.value), mode: mode, limits: limits,
            ceiling: operationCeiling
        )
    }

    /// The mutating protocol calls of a run, with `removeTree` counted once; nil on overflow or a negative count.
    /// createNew: root, manifest, d + f entries, d + 1 syncs, rename, parent sync = 5 + 2d + f.
    /// replaceExisting adds the retire rename and the backup removal = 7 + 2d + f.
    static func operationCount(directories: Int, files: Int, mode: StagingMode) -> Int? {
        guard directories >= 0, files >= 0 else { return nil }
        let (doubled, doubleOverflow) = directories.multipliedReportingOverflow(by: 2)
        let (entries, entryOverflow) = doubled.addingReportingOverflow(files)
        let fixed = mode == .createNew ? 5 : 7
        let (total, totalOverflow) = entries.addingReportingOverflow(fixed)
        guard !doubleOverflow, !entryOverflow, !totalOverflow else { return nil }
        return total
    }

    func admitOperations(directories: Int, files: Int) throws(StagingRefusal) {
        guard let count = Self.operationCount(directories: directories, files: files, mode: mode),
              count <= operationCeiling else { throw .operationBudgetExceeded }
    }

    private static func admitted(
        _ path: String, limits: ProjectPackageLimits
    ) throws(StagingRefusal) -> ProjectPackagePath {
        do {
            return try ProjectPackagePath(path, limits: limits)
        } catch {
            throw .package(error)
        }
    }

    /// The part of `path` after `prefix` and a "/" separator, or nil when `path` is not beneath `prefix`.
    /// Compared by unicode scalars: a Character-based prefix test would merge "/" with a following combining mark.
    static func remainder(of path: String, beneath prefix: String) -> String? {
        let scalars = path.unicodeScalars
        let prefixScalars = prefix.unicodeScalars
        guard scalars.count > prefixScalars.count, scalars.starts(with: prefixScalars) else { return nil }
        let rest = scalars.dropFirst(prefixScalars.count)
        guard rest.first == "/" else { return nil }
        return String(rest.dropFirst())
    }

    /// Whether `other` is `path` itself or lies beneath it.
    static func isWithin(_ other: String, of path: String) -> Bool {
        other.utf8.elementsEqual(path.utf8) || remainder(of: other, beneath: path) != nil
    }

    /// True when the source is, contains or lies beneath any of the plan's three names.
    func overlaps(_ source: String) -> Bool {
        [destination, stagingPath, backupPath].contains {
            Self.isWithin(source, of: $0) || Self.isWithin($0, of: source)
        }
    }

    static func join(_ base: String, _ child: String) -> String {
        if child.isEmpty { return base }
        return base.isEmpty ? child : base + "/" + child
    }
}
