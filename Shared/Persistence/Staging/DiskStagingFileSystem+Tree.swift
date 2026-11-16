import Foundation

/// The point of a `DiskStagingFileSystem.removeTree` walk that a test hook fires at.
enum DiskStagingTreePhase: Sendable, Equatable {
    /// The removal root, after its status and before its device is checked against the staging volume.
    case root
    /// A descendant in the count phase, before its status is read.
    case count
    /// A counted directory, after its status was admitted and before it is opened.
    case countOpen
    /// A descendant in the remove phase, before its status is read.
    case remove
    /// A directory in the remove phase, after its status was admitted and before it is opened.
    case removeOpen
}

/// Bounded, no-follow tree removal and chunked reads for `DiskStagingFileSystem`.
extension DiskStagingFileSystem {
    /// One removal phase: its node and depth allowance, the removal root's device, the recorded directories and the
    /// test hook.
    private struct TreeWalk {
        let phase: DiskStagingTreePhase
        var remainingNodes: Int
        let maxDepth: Int
        let device: dev_t
        let recorded: [[UInt8]: ProjectPackageDirectoryIdentity]
        let hook: ((DiskStagingTreePhase, String) -> dev_t?)?

        init(
            _ phase: DiskStagingTreePhase, root: stat, recorded: [[UInt8]: ProjectPackageDirectoryIdentity],
            of adapter: DiskStagingFileSystem
        ) {
            // The manifest is not a package entry, so a staging tree holds at most `maxEntries + 1` nodes.
            let (nodes, overflow) = adapter.limits.maxEntries.addingReportingOverflow(1)
            self.phase = phase
            remainingNodes = overflow ? Int.max : nodes
            maxDepth = adapter.limits.maxDepth
            device = root.st_dev
            self.recorded = recorded
            hook = adapter.treeVisitHookForTesting
        }

        /// Fires the hook between a directory's admitted status and opening it; its result is ignored.
        func willOpen(_ path: String) {
            _ = hook?(phase == .count ? .countOpen : .removeOpen, path)
        }

        mutating func admit(depth: Int) throws(StagingIOFault) {
            guard remainingNodes > 0, depth <= maxDepth else { throw .tooManyEntries }
            remainingNodes -= 1
        }

        /// The no-follow status of `name` and the status as observed for the device check (the hook may stand in
        /// for the device).
        func visit(_ directory: Int32, _ name: String, path: String) throws(StagingIOFault) -> (stat, stat) {
            let device = hook?(phase, path)
            let info = try DiskStagingFileSystem.childStatus(directory, name)
            var observed = info
            if let device { observed.st_dev = device }
            return (info, observed)
        }
    }

    /// Removes one node beneath `parent`. A link or file is unlinked, never followed. A directory is opened and checked
    /// against its admitted status (device and inode), counted first, so an over-limit tree, a descendant on another
    /// device or a replaced recorded descendant is refused with nothing removed, then removed bottom-up under the same
    /// bound and checks.
    /// The caller has already admitted the root's device against the staging volume's.
    func removeNode(
        _ name: String, _ info: stat, in parent: Int32, path: String,
        recorded: [[UInt8]: ProjectPackageDirectoryIdentity]
    ) throws(StagingIOFault) {
        guard ProjectPackageFileSystem.kind(info) == .directory else {
            guard unlinkat(parent, name, 0) == 0 else { throw Self.fault(errno: errno) }
            return
        }
        let directory = try Self.openDirectory(name, in: parent, matching: info)
        defer { Darwin.close(directory) }
        var counting = TreeWalk(.count, root: info, recorded: recorded, of: self)
        try Self.count(directory, path: path, depth: 0, &counting)
        var removing = TreeWalk(.remove, root: info, recorded: recorded, of: self)
        try Self.removeContents(directory, path: path, depth: 0, &removing)
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Self.fault(errno: errno) }
    }

    /// A descendant on another device than the removal root (a mount point or anything beneath one) is `.crossVolume`.
    static func admitDevice(_ info: stat, root device: dev_t) throws(StagingIOFault) {
        guard info.st_dev == device else { throw .crossVolume }
    }

    /// A recorded descendant must still be the directory `makeDirectory` recorded, else `.changed`.
    static func admitRecorded(
        _ info: stat, path: String, recorded: [[UInt8]: ProjectPackageDirectoryIdentity]
    ) throws(StagingIOFault) {
        guard let expected = recorded[Array(path.utf8)] else { return }
        guard ProjectPackageFileSystem.kind(info) == .directory,
              ProjectPackageDirectoryIdentity(info) == expected else {
            throw .changed
        }
    }

    private static func count(
        _ directory: Int32, path: String, depth: Int, _ walk: inout TreeWalk
    ) throws(StagingIOFault) {
        for name in try names(in: directory, limit: walk.remainingNodes) {
            let child = StagingPlan.join(path, name)
            let (info, observed) = try walk.visit(directory, name, path: child)
            try walk.admit(depth: depth + 1)
            try admitDevice(observed, root: walk.device)
            try admitRecorded(info, path: child, recorded: walk.recorded)
            guard ProjectPackageFileSystem.kind(info) == .directory else { continue }
            walk.willOpen(child)
            // The opened descriptor must match the admitted status (device and inode), so it is on the same device.
            let opened = try openDirectory(name, in: directory, matching: info)
            defer { Darwin.close(opened) }
            try count(opened, path: child, depth: depth + 1, &walk)
        }
    }

    private static func removeContents(
        _ directory: Int32, path: String, depth: Int, _ walk: inout TreeWalk
    ) throws(StagingIOFault) {
        for name in try names(in: directory, limit: walk.remainingNodes) {
            let child = StagingPlan.join(path, name)
            let (info, observed) = try walk.visit(directory, name, path: child)
            try walk.admit(depth: depth + 1)
            try admitDevice(observed, root: walk.device)
            try admitRecorded(info, path: child, recorded: walk.recorded)
            guard ProjectPackageFileSystem.kind(info) == .directory else {
                guard unlinkat(directory, name, 0) == 0 else { throw fault(errno: errno) }
                continue
            }
            walk.willOpen(child)
            // As in `count`, the opened descriptor must match the admitted status, device included.
            let opened = try openDirectory(name, in: directory, matching: info)
            defer { Darwin.close(opened) }
            try removeContents(opened, path: child, depth: depth + 1, &walk)
            guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw fault(errno: errno) }
        }
    }

    /// Lists through a fresh descriptor for the same directory: `names(in:)` reads a `dup`, which shares the
    /// directory offset, so a second listing through the original descriptor would start at its end. Used by every
    /// listing, the root's included.
    static func names(in directory: Int32, limit: Int) throws(StagingIOFault) -> [String] {
        let fresh = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fresh >= 0 else { throw fault(errno: errno) }
        defer { Darwin.close(fresh) }
        do { return try ProjectPackageFileSystem.names(in: fresh, limit: limit) } catch { throw fault(error) }
    }

    private static func childStatus(_ directory: Int32, _ name: String) throws(StagingIOFault) -> stat {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fault(errno: errno) }
        return info
    }

    /// Opens a directory that was just stat'ed; anything else at that name now is `.changed`.
    private static func openDirectory(
        _ name: String, in parent: Int32, matching info: stat
    ) throws(StagingIOFault) -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ENOENT || code == ENOTDIR || code == ELOOP ? .changed : fault(errno: code)
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              ProjectPackageDirectoryIdentity(opened) == ProjectPackageDirectoryIdentity(info) else {
            Darwin.close(descriptor)
            throw .changed
        }
        return descriptor
    }

    /// At most `count` bytes from `offset`, fewer only at end of file; `EINTR` is retried.
    static func readBytes(_ descriptor: Int32, offset: Int, count: Int) throws(StagingIOFault) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 65_536))
        while data.count < count {
            let (position, overflow) = offset.addingReportingOverflow(data.count)
            guard !overflow else { throw .ioError }
            let request = min(count - data.count, buffer.count)
            let delivered = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, request, off_t(position))
            }
            if delivered < 0 {
                guard errno == EINTR else { throw fault(errno: errno) }
                continue
            }
            if delivered == 0 { break }
            data.append(contentsOf: buffer[..<delivered])
        }
        return data
    }
}
