import Foundation

/// Bounded diagnostics for package IO; never retains an untrusted path, payload, or error text.
enum ProjectPackageIOError: Error, Sendable, Equatable {
    case missingMember
    case digestMismatch
    case memberChanged
    case hardLinkedMember
    case crossedMountPoint
    case destinationExists
    /// The destination's parent is a link or not a directory; it is never followed.
    case destinationParentRefused
    case system(code: Int32)
}

/// Descriptor-relative, no-follow primitives. Each component is opened from its already-open
/// parent with `O_NOFOLLOW`, so no link is resolved at any level of the package.
enum ProjectPackageFileSystem {
    static func openRoot(_ url: URL) throws -> Int32 {
        let (descriptor, code) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            return (descriptor, errno)
        }
        guard descriptor >= 0 else { throw ProjectPackageIOError.system(code: code) }
        return descriptor
    }

    /// Creates a new directory beneath the no-follow-opened parent, then opens that name relative to
    /// the same parent descriptor; the destination is never re-resolved by path. An existing name,
    /// including a link, is refused rather than reused. Ancestors of the parent resolve normally.
    static func createRoot(_ url: URL) throws -> Int32 {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw ProjectPackageError.invalidPath }
        let parent: Int32
        do {
            parent = try openRoot(url.deletingLastPathComponent())
        } catch ProjectPackageIOError.system(let code) where code == ELOOP || code == ENOTDIR {
            throw ProjectPackageIOError.destinationParentRefused
        }
        defer { close(parent) }
        guard mkdirat(parent, name, 0o755) == 0 else {
            guard errno != EEXIST else { throw ProjectPackageIOError.destinationExists }
            throw failure()
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        return descriptor
    }

    static func status(of descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        return info
    }

    /// Size, modification and status-change times; a mismatch means the member changed while open.
    static func sameContentState(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func status(at directory: Int32, _ name: String) throws -> stat {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        return info
    }

    static func kind(_ info: stat) -> ProjectPackageEntryKind {
        switch info.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .regularFile
        case S_IFLNK: .symbolicLink
        default: .unsupported
        }
    }

    /// Opens only the inode that was admitted; a replaced or retyped name refuses.
    /// Returns the descriptor and its opened status, the baseline for change detection.
    static func openMember(
        at directory: Int32, _ name: String, matching info: stat
    ) throws -> (descriptor: Int32, status: stat) {
        let directoryFlag = kind(info) == .directory ? O_DIRECTORY : 0
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | directoryFlag)
        guard descriptor >= 0 else { throw failure() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            let code = errno
            close(descriptor)
            throw ProjectPackageIOError.system(code: code)
        }
        guard opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_mode & S_IFMT == info.st_mode & S_IFMT else {
            close(descriptor)
            throw ProjectPackageIOError.memberChanged
        }
        return (descriptor, opened)
    }

    /// Lists at most `limit` names (excluding dot entries), sorted by UTF-8 bytes.
    static func names(in directory: Int32, limit: Int) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { throw failure() }
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw ProjectPackageIOError.system(code: code)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw failure() }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = try withUnsafeBytes(of: entry.pointee.d_name) { raw throws -> String in
                guard let name = String(validating: raw.prefix(length), as: UTF8.self) else {
                    throw ProjectPackageError.invalidPath
                }
                return name
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < limit else { throw ProjectPackageError.entryLimitExceeded }
            names.append(name)
        }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// One request of at most `count` bytes; zero means the descriptor reported EOF.
    static func readChunk(_ descriptor: Int32, into buffer: inout [UInt8], count: Int) throws -> Int {
        precondition(count > 0 && count <= buffer.count)
        while true {
            let delivered = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, count) }
            if delivered >= 0 { return delivered }
            guard errno == EINTR else { throw failure() }
        }
    }

    /// Opens `components` beneath `root` one no-follow directory at a time; the caller closes the result.
    static func openDirectory(at root: Int32, _ components: [String]) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw failure() }
        for component in components {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(current)
            guard next >= 0 else { throw ProjectPackageIOError.system(code: code) }
            current = next
        }
        return current
    }

    static func createDirectory(at directory: Int32, _ name: String) throws {
        guard mkdirat(directory, name, 0o755) == 0 else { throw failure() }
    }

    /// Exclusive create, complete write and `fsync`; never truncates or follows an existing name.
    static func createFile(at directory: Int32, _ name: String, bytes: Data) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    guard errno == EINTR else { throw failure() }
                    continue
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw failure() }
    }

    private static func failure() -> ProjectPackageIOError {
        .system(code: errno)
    }
}
