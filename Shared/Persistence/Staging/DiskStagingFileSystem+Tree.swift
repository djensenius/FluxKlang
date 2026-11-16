import Foundation

/// Bounded, no-follow tree removal and chunked reads for `DiskStagingFileSystem`.
extension DiskStagingFileSystem {
    /// The node and depth allowance of one removal phase.
    private struct TreeBudget {
        var remainingNodes: Int
        let maxDepth: Int

        init(_ limits: ProjectPackageLimits) {
            // The manifest is not a package entry, so a staging tree holds at most `maxEntries + 1` nodes.
            let (nodes, overflow) = limits.maxEntries.addingReportingOverflow(1)
            remainingNodes = overflow ? Int.max : nodes
            maxDepth = limits.maxDepth
        }

        mutating func admit(depth: Int) throws(StagingIOFault) {
            guard remainingNodes > 0, depth <= maxDepth else { throw .tooManyEntries }
            remainingNodes -= 1
        }
    }

    /// Removes one node beneath `parent`. A link or file is unlinked, never followed. A directory is counted first,
    /// so an over-limit tree is refused with nothing removed, then removed bottom-up under the same bound.
    static func removeNode(
        _ name: String, _ info: stat, in parent: Int32, limits: ProjectPackageLimits
    ) throws(StagingIOFault) {
        guard ProjectPackageFileSystem.kind(info) == .directory else {
            guard unlinkat(parent, name, 0) == 0 else { throw fault(errno: errno) }
            return
        }
        let directory = try openDirectory(name, in: parent, matching: info)
        defer { Darwin.close(directory) }
        var counting = TreeBudget(limits)
        try count(directory, depth: 0, &counting)
        var removing = TreeBudget(limits)
        try removeContents(directory, depth: 0, &removing)
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw fault(errno: errno) }
    }

    private static func count(_ directory: Int32, depth: Int, _ budget: inout TreeBudget) throws(StagingIOFault) {
        for name in try names(in: directory, limit: budget.remainingNodes) {
            let info = try childStatus(directory, name)
            try budget.admit(depth: depth + 1)
            guard ProjectPackageFileSystem.kind(info) == .directory else { continue }
            let child = try openDirectory(name, in: directory, matching: info)
            defer { Darwin.close(child) }
            try count(child, depth: depth + 1, &budget)
        }
    }

    private static func removeContents(
        _ directory: Int32, depth: Int, _ budget: inout TreeBudget
    ) throws(StagingIOFault) {
        for name in try names(in: directory, limit: budget.remainingNodes) {
            let info = try childStatus(directory, name)
            try budget.admit(depth: depth + 1)
            guard ProjectPackageFileSystem.kind(info) == .directory else {
                guard unlinkat(directory, name, 0) == 0 else { throw fault(errno: errno) }
                continue
            }
            let child = try openDirectory(name, in: directory, matching: info)
            defer { Darwin.close(child) }
            try removeContents(child, depth: depth + 1, &budget)
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
