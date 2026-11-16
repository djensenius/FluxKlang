import Foundation

/// The primitive a `DiskStagingFileSystem` test hook fires for.
enum DiskStagingOperation: Sendable, Equatable {
    case status
    case listDirectory
    case read
    case makeDirectory
    case createFile
    case syncDirectory
    case rename
    case removeTree
}

/// A `StagingFileSystem` over one real directory, the volume root, which stays open by descriptor (with its parent)
/// for the adapter's lifetime. Every path is resolved from that descriptor one no-follow component at a time, so no
/// link is followed and nothing outside the root is reached.
///
/// - Paths are split by unicode scalars; an empty, `.` or `..` component, or one containing NUL, is `.denied` before
///   any IO. The empty path is the root; it can be read but never created, renamed or removed (`.denied`).
/// - Before every primitive the root's name is re-checked in its held parent; a renamed, replaced or retyped root is
///   `.changed`. Each directory made with `makeDirectory` has its device and inode recorded; a recorded component
///   that is missing, a link, not a directory or another directory is `.changed`. An unrecorded component that is
///   missing or a regular file makes the path absent (`status` returns nil, other primitives throw `.notFound`); one
///   that is a link or another kind is `.changed`. `rename` and `removeTree` forget the records at or beneath their
///   paths; nothing is re-keyed. The table is keyed by the path's UTF-8 bytes (not `String` equality, which treats
///   NFC and NFD as equal), so an alias spelling of a recorded directory (case or normalization on an insensitive
///   volume) is resolved as unrecorded, and `forget` removes exactly the byte spellings it is given.
/// - Every listing reads through a fresh `openat(…, ".")` descriptor, so no listing consumes a directory offset
///   shared with the held root or another descriptor.
/// - `status` is `fstatat(AT_SYMLINK_NOFOLLOW)`: volume is `st_dev`, identity `st_ino`, the byte count is the size of
///   a regular file (otherwise 0) and the generation is the status-change time in nanoseconds.
/// - `createFile` is an exclusive, no-follow create followed by `fsync`; `syncDirectory` is `fsync`, not
///   `F_FULLFSYNC`. `rename` is `renameatx_np(RENAME_EXCL)`, so it never replaces; `EXDEV` is `.crossVolume`.
/// - `removeTree` never follows a link and never removes a recorded directory whose identity changed. A directory is
///   first counted (at most `maxEntries + 1` nodes, the manifest included, and `maxDepth` levels beneath it, otherwise
///   `.tooManyEntries` with nothing removed), then removed bottom-up under the same bound.
/// - Errors: `ENOSPC`/`EDQUOT` are `.noSpace`; `EACCES`/`EPERM`/`EROFS` `.denied`; `EEXIST`/`ENOTEMPTY` `.exists`;
///   `ENOENT` `.notFound`; `EXDEV` `.crossVolume`; anything else `.ioError`. Nothing reports `.interrupted`: only the
///   `pread` loop retries `EINTR`; any other call that sees it surfaces `.ioError` (rare on Darwin for local files).
///
/// Threading: single owner, not thread-safe. The identity table and the test hook are unsynchronised.
///
/// Limits: this detects concurrent mutation, it does not prevent it (a change between a check and the call it
/// guards is not caught). It is not a file coordinator. A replace is two renames, not an atomic swap. The backup name
/// lies inside the confined root but was never created by this adapter, so it is not identity-checked before it is
/// removed. Device identity is compared but only one volume is exercised by tests.
final class DiskStagingFileSystem: StagingFileSystem {
    private typealias FileSystem = ProjectPackageFileSystem

    /// Test-only interleaving point: fires with the primitive and its (source) path after the lexical path check and
    /// before any IO or identity check. Nil in production.
    var operationHookForTesting: ((DiskStagingOperation, String) -> Void)?
    let limits: ProjectPackageLimits
    private let root: ProjectPackageWriteRoot
    /// Keyed by the path's UTF-8 bytes, like `StagingPlan.isWithin`, so lookups and `forget` agree on spelling.
    private var identities: [[UInt8]: ProjectPackageDirectoryIdentity] = [:]
    private var isClosed = false

    /// Opens `root` without following a link. A parent that is a link or not a directory is
    /// `.packageIO(.destinationParentRefused)`; a root that is missing, a link or not a directory is
    /// `.destinationRefused`; any other failure is `.ioFailed(step: .preflight, …)`.
    init(root url: URL, limits: ProjectPackageLimits) throws(StagingRefusal) {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw .destinationRefused }
        let parent: Int32
        do {
            parent = try FileSystem.openRoot(url.deletingLastPathComponent())
        } catch {
            throw Self.openRefusal(error, refused: .packageIO(.destinationParentRefused))
        }
        let opened: (descriptor: Int32, identity: ProjectPackageDirectoryIdentity)
        do {
            opened = try FileSystem.openDestinationDirectory(at: parent, name, matching: nil)
        } catch {
            Darwin.close(parent)
            throw Self.openRefusal(error, refused: .destinationRefused)
        }
        root = ProjectPackageWriteRoot(
            parent: parent, descriptor: opened.descriptor, name: name, identity: opened.identity
        )
        self.limits = limits
    }

    deinit {
        close()
    }

    /// Releases the root descriptors; every later primitive throws `.ioError`.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        root.close()
    }

    // MARK: StagingFileSystem

    func status(at path: String) throws(StagingIOFault) -> StagingNodeStatus? {
        let components = try begin(.status, path)
        guard let leaf = Self.split(components) else {
            do { return try Self.nodeStatus(FileSystem.status(of: root.descriptor)) } catch { throw Self.fault(error) }
        }
        guard let parent = try openChain(leaf.parent) else { return nil }
        defer { Darwin.close(parent) }
        return try leafStatus(parent, leaf.name, path: path).map(Self.nodeStatus)
    }

    func listDirectory(at path: String, limit: Int) throws(StagingIOFault) -> [String] {
        let components = try begin(.listDirectory, path)
        guard let directory = try openChain(components) else { throw .notFound }
        defer { Darwin.close(directory) }
        return try Self.names(in: directory, limit: max(limit, 0))
    }

    func read(at path: String, offset: Int, count: Int) throws(StagingIOFault) -> Data {
        guard offset >= 0, count >= 0 else { throw .ioError }
        let components = try begin(.read, path)
        guard let leaf = Self.split(components), let parent = try openChain(leaf.parent) else { throw .notFound }
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, leaf.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ELOOP ? .notFound : Self.fault(errno: code)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.fault(errno: errno) }
        guard FileSystem.kind(info) == .regularFile else { throw .notFound }
        return try Self.readBytes(descriptor, offset: offset, count: count)
    }

    func makeDirectory(at path: String) throws(StagingIOFault) {
        let leaf = try beginLeaf(.makeDirectory, path)
        guard let parent = try openChain(leaf.parent) else { throw .notFound }
        defer { Darwin.close(parent) }
        guard mkdirat(parent, leaf.name, 0o755) == 0 else { throw Self.fault(errno: errno) }
        do {
            let opened = try FileSystem.openDestinationDirectory(at: parent, leaf.name, matching: nil)
            Darwin.close(opened.descriptor)
            identities[Array(path.utf8)] = opened.identity
        } catch {
            throw Self.fault(error)
        }
    }

    func createFile(at path: String, bytes: Data) throws(StagingIOFault) {
        let leaf = try beginLeaf(.createFile, path)
        guard let parent = try openChain(leaf.parent) else { throw .notFound }
        defer { Darwin.close(parent) }
        do { try FileSystem.createFile(at: parent, leaf.name, bytes: bytes) } catch { throw Self.fault(error) }
    }

    func syncDirectory(at path: String) throws(StagingIOFault) {
        let components = try begin(.syncDirectory, path)
        guard let directory = try openChain(components) else { throw .notFound }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw Self.fault(errno: errno) }
    }

    func rename(from source: String, to destination: String) throws(StagingIOFault) {
        guard let target = try Self.split(Self.components(of: destination)) else { throw .denied }
        let leaf = try beginLeaf(.rename, source)
        guard let from = try openChain(leaf.parent) else { throw .notFound }
        defer { Darwin.close(from) }
        guard try leafStatus(from, leaf.name, path: source) != nil else { throw .notFound }
        guard let into = try openChain(target.parent) else { throw .notFound }
        defer { Darwin.close(into) }
        guard renameatx_np(from, leaf.name, into, target.name, UInt32(RENAME_EXCL)) == 0 else {
            throw Self.fault(errno: errno)
        }
        forget(source)
        forget(destination)
    }

    func removeTree(at path: String) throws(StagingIOFault) {
        let leaf = try beginLeaf(.removeTree, path)
        guard let parent = try openChain(leaf.parent) else { throw .notFound }
        defer { Darwin.close(parent) }
        guard let info = try leafStatus(parent, leaf.name, path: path) else { throw .notFound }
        try Self.removeNode(leaf.name, info, in: parent, limits: limits)
        forget(path)
    }

    // MARK: Resolution

    /// The lexical check, the test hook, then the root's identity.
    private func begin(_ operation: DiskStagingOperation, _ path: String) throws(StagingIOFault) -> [String] {
        guard !isClosed else { throw .ioError }
        let components = try Self.components(of: path)
        operationHookForTesting?(operation, path)
        do { try FileSystem.verifyRoot(root) } catch { throw Self.fault(error) }
        return components
    }

    /// `begin` for a primitive that names a node beneath the root; the root itself is `.denied`.
    private func beginLeaf(
        _ operation: DiskStagingOperation, _ path: String
    ) throws(StagingIOFault) -> (parent: [String], name: String) {
        guard !path.isEmpty else { throw .denied }
        guard let leaf = try Self.split(begin(operation, path)) else { throw .denied }
        return leaf
    }

    /// Opens `components` beneath the root one no-follow directory at a time; nil when one is absent. The caller
    /// closes the result.
    private func openChain(_ components: [String]) throws(StagingIOFault) -> Int32? {
        var current = dup(root.descriptor)
        guard current >= 0 else { throw Self.fault(errno: errno) }
        var path = ""
        for component in components {
            path = StagingPlan.join(path, component)
            let next: Int32?
            do {
                next = try openComponent(at: current, component, path: path)
            } catch {
                Darwin.close(current)
                throw error
            }
            Darwin.close(current)
            guard let next else { return nil }
            current = next
        }
        return current
    }

    private func openComponent(at parent: Int32, _ name: String, path: String) throws(StagingIOFault) -> Int32? {
        if let expected = identities[Array(path.utf8)] {
            do {
                return try FileSystem.openDestinationDirectory(at: parent, name, matching: expected).descriptor
            } catch {
                throw Self.fault(error)
            }
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor < 0 else { return descriptor }
        let code = errno
        switch code {
        case ENOENT:
            return nil
        case ENOTDIR, ELOOP:
            // Darwin reports a link as ENOTDIR under O_DIRECTORY|O_NOFOLLOW; only a regular file means absent.
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                if code == ENOENT { return nil }
                throw Self.fault(errno: code)
            }
            guard FileSystem.kind(info) == .regularFile else { throw .changed }
            return nil
        default:
            throw Self.fault(errno: code)
        }
    }

    /// The no-follow status of `name` in `parent`, nil when absent. A recorded directory must still be itself.
    private func leafStatus(_ parent: Int32, _ name: String, path: String) throws(StagingIOFault) -> stat? {
        var info = stat()
        let expected = identities[Array(path.utf8)]
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            guard code == ENOENT else { throw Self.fault(errno: code) }
            if expected != nil { throw .changed }
            return nil
        }
        if let expected {
            guard FileSystem.kind(info) == .directory, ProjectPackageDirectoryIdentity(info) == expected else {
                throw .changed
            }
        }
        return info
    }

    /// Drops the records at or beneath `path`, comparing UTF-8 bytes exactly as `StagingPlan.isWithin` does.
    private func forget(_ path: String) {
        let prefix = Array(path.utf8)
        let beneath = prefix + [UInt8(ascii: "/")]
        identities = identities.filter { key, _ in key != prefix && !key.starts(with: beneath) }
    }

    // MARK: Helpers

    /// Unicode-scalar components; empty, `.`, `..` and NUL-containing components are refused before any IO.
    static func components(of path: String) throws(StagingIOFault) -> [String] {
        guard !path.isEmpty else { return [] }
        var result: [String] = []
        for scalars in path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false) {
            let isDots = scalars.allSatisfy { $0 == "." } && scalars.count <= 2
            guard !scalars.isEmpty, !isDots, !scalars.contains("\u{0}") else { throw .denied }
            result.append(String(String.UnicodeScalarView(scalars)))
        }
        return result
    }

    private static func split(_ components: [String]) -> (parent: [String], name: String)? {
        guard let name = components.last else { return nil }
        return (Array(components.dropLast()), name)
    }

    static func nodeStatus(_ info: stat) -> StagingNodeStatus {
        let kind = FileSystem.kind(info)
        let seconds = UInt64(truncatingIfNeeded: info.st_ctimespec.tv_sec)
        let nanoseconds = UInt64(truncatingIfNeeded: info.st_ctimespec.tv_nsec)
        return StagingNodeStatus(
            kind: kind, byteCount: kind == .regularFile ? Int(info.st_size) : 0, linkCount: Int(info.st_nlink),
            volume: Int(info.st_dev), generation: seconds &* 1_000_000_000 &+ nanoseconds,
            identity: UInt64(info.st_ino)
        )
    }

    static func fault(errno code: Int32) -> StagingIOFault {
        switch code {
        case ENOSPC, EDQUOT: .noSpace
        case EACCES, EPERM, EROFS: .denied
        case EEXIST, ENOTEMPTY: .exists
        case ENOENT: .notFound
        case EXDEV: .crossVolume
        default: .ioError
        }
    }

    static func fault(_ error: any Error) -> StagingIOFault {
        switch error {
        case let error as StagingIOFault: error
        case ProjectPackageIOError.destinationChanged: .changed
        case let ProjectPackageIOError.system(code): fault(errno: code)
        case ProjectPackageError.entryLimitExceeded: .tooManyEntries
        default: .ioError
        }
    }

    private static func openRefusal(_ error: any Error, refused: StagingRefusal) -> StagingRefusal {
        switch error {
        case ProjectPackageIOError.destinationChanged: refused
        case let ProjectPackageIOError.system(code) where code == ELOOP || code == ENOTDIR: refused
        default: .ioFailed(step: .preflight, fault: fault(error), cleanup: .notNeeded)
        }
    }
}
