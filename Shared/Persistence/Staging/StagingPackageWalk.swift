import Foundation

/// A bounded, no-follow walk of a package tree on a `StagingFileSystem`, mirroring the P3 reader's semantics:
/// status first, then P1 admission, then placement checks, then chunked reads that always probe one byte past the
/// remaining allowance, then a second status that must show the same generation and size.
struct StagingPackageWalk {
    private static let manifestName = ProjectPackageManifest.manifestMemberPath

    private let policy: ProjectPackageManifestPolicy
    private let chunkByteCount: Int
    private let step: StagingStep
    private var admission: ProjectPackageAdmission
    private var directories: [String] = []
    private var files: [String: Data] = [:]
    private var declared: [String: Int] = [:]
    private var rootVolume = 0

    /// `step` names the stage an IO fault is attributed to.
    init(policy: ProjectPackageManifestPolicy, chunkByteCount: Int, step: StagingStep) throws(StagingRefusal) {
        guard chunkByteCount >= 1 else { throw .invalidChunkSize }
        self.policy = policy
        self.chunkByteCount = chunkByteCount
        self.step = step
        admission = ProjectPackageAdmission(limits: policy.packageLimits)
    }

    mutating func run<FS: StagingFileSystem>(
        root: String, in store: inout FS
    ) throws(StagingRefusal) -> ProjectPackageContents {
        guard let rootStatus = try status(root, &store), rootStatus.kind == .directory else {
            throw .packageIO(.missingMember)
        }
        rootVolume = rootStatus.volume
        let manifestBytes = try readManifest(root: root, &store)
        do {
            declared = try ProjectPackageManifest.decode(from: manifestBytes, policy: policy).declaredMemberByteCounts
        } catch {
            throw StagingRefusal.wrapping(error)
        }
        try walk(directory: "", root: root, &store)
        do {
            try admission.validateComplete()
            return try ProjectPackageContents(
                manifestBytes: manifestBytes, directories: directories, files: files, policy: policy
            )
        } catch {
            throw StagingRefusal.wrapping(error)
        }
    }

    private mutating func readManifest<FS: StagingFileSystem>(
        root: String, _ store: inout FS
    ) throws(StagingRefusal) -> Data {
        let path = StagingPlan.join(root, Self.manifestName)
        guard let first = try status(path, &store), first.kind == .regularFile else { throw .packageIO(.missingMember) }
        try admit(Self.manifestName, first, declaredByteCount: nil)
        let bytes = try readAll(path, manifestCap: policy.maxManifestBytes, &store)
        try confirmUnchanged(path, first, byteCount: bytes.count, &store)
        return bytes
    }

    private mutating func walk<FS: StagingFileSystem>(
        directory: String, root: String, _ store: inout FS
    ) throws(StagingRefusal) {
        let isRoot = directory.isEmpty
        let limit = max(policy.packageLimits.maxEntries - admission.entryCount + (isRoot ? 1 : 0), 0)
        let listing = try list(StagingPlan.join(root, directory), limit: limit, &store)
        for name in try Self.ordered(listing) where !(isRoot && name == Self.manifestName) {
            try visit(StagingPlan.join(directory, name), root: root, &store)
        }
    }

    private mutating func visit<FS: StagingFileSystem>(
        _ relative: String, root: String, _ store: inout FS
    ) throws(StagingRefusal) {
        let full = StagingPlan.join(root, relative)
        guard let status = try status(full, &store) else { throw .packageIO(.memberChanged) }
        try admit(relative, status, declaredByteCount: declared[relative])
        switch status.kind {
        case .directory:
            directories.append(relative)
            try walk(directory: relative, root: root, &store)
        case .regularFile:
            let bytes = try readAll(full, manifestCap: nil, &store)
            try confirmUnchanged(full, status, byteCount: bytes.count, &store)
            files[relative] = bytes
        case .symbolicLink, .unsupported:
            // `admit` already refused these kinds; this branch is unreachable.
            throw .package(.unsupportedKind)
        }
    }

    private mutating func admit(
        _ path: String, _ status: StagingNodeStatus, declaredByteCount: Int?
    ) throws(StagingRefusal) {
        do {
            try admission.admit(path: path, kind: status.kind, declaredByteCount: declaredByteCount)
        } catch {
            throw .package(error)
        }
        guard status.volume == rootVolume else { throw .packageIO(.crossedMountPoint) }
        guard status.kind != .regularFile || status.linkCount == 1 else { throw .packageIO(.hardLinkedMember) }
    }

    private mutating func readAll<FS: StagingFileSystem>(
        _ path: String, manifestCap: Int?, _ store: inout FS
    ) throws(StagingRefusal) -> Data {
        var data = Data()
        while true {
            let allowance = manifestCap.map { $0 - data.count } ?? admission.remainingReadableBytes
            let request = max(min(chunkByteCount, allowance), 1)
            let part = try read(path, offset: data.count, count: request, &store)
            guard part.count <= request else { throw .ioFailed(step: step, fault: .ioError, cleanup: .notNeeded) }
            if part.isEmpty { return data }
            data.append(part)
            if let manifestCap, data.count > manifestCap { throw .manifest(.manifestBytesExceeded) }
            do {
                try admission.consume(byteCount: part.count)
            } catch {
                throw .package(error)
            }
        }
    }

    private mutating func confirmUnchanged<FS: StagingFileSystem>(
        _ path: String, _ before: StagingNodeStatus, byteCount: Int, _ store: inout FS
    ) throws(StagingRefusal) {
        guard let after = try status(path, &store), after.generation == before.generation,
              after.byteCount == before.byteCount, after.byteCount == byteCount else {
            throw .packageIO(.memberChanged)
        }
        do {
            try admission.finishFile()
        } catch {
            throw .package(error)
        }
    }

    /// Names are single non-empty components; they are re-sorted by UTF-8 bytes whatever order the volume gave.
    private static func ordered(_ names: [String]) throws(StagingRefusal) -> [String] {
        for name in names where name.isEmpty || name.utf8.contains(UInt8(ascii: "/")) {
            throw .package(.invalidPath)
        }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private func fail(_ fault: StagingIOFault) -> StagingRefusal {
        if fault == .tooManyEntries { return .package(.entryLimitExceeded) }
        return .ioFailed(step: step, fault: fault, cleanup: .notNeeded)
    }

    private func status<FS: StagingFileSystem>(
        _ path: String, _ store: inout FS
    ) throws(StagingRefusal) -> StagingNodeStatus? {
        do { return try store.status(at: path) } catch { throw fail(error) }
    }

    private func list<FS: StagingFileSystem>(
        _ path: String, limit: Int, _ store: inout FS
    ) throws(StagingRefusal) -> [String] {
        do { return try store.listDirectory(at: path, limit: limit) } catch { throw fail(error) }
    }

    private func read<FS: StagingFileSystem>(
        _ path: String, offset: Int, count: Int, _ store: inout FS
    ) throws(StagingRefusal) -> Data {
        do { return try store.read(at: path, offset: offset, count: count) } catch { throw fail(error) }
    }
}
