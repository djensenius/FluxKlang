import Foundation

/// Identity bookkeeping for one package write. Each directory the writer creates is opened once, its
/// `(st_dev, st_ino)` recorded and the descriptor closed, so no descriptor is held per directory and the
/// table never exceeds the admitted entries. Before an entry is created, the destination's name and its
/// parent chain are re-opened from the root and compared with the table; afterwards, or when the create
/// fails, the held parent is checked again by name (a failed create whose parent still matches keeps its
/// own error); after the last entry every recorded directory is re-walked. A mismatch, a missing name, a
/// link or a non-directory refuses with `destinationChanged`. This detects concurrent mutation; it does
/// not prevent it, and output already written is never removed.
struct ProjectPackageWriteSession {
    private typealias FileSystem = ProjectPackageFileSystem

    private let root: ProjectPackageWriteRoot
    private let hook: (@Sendable (ProjectPackageWriteStage, String) -> Void)?
    private var identities: [String: ProjectPackageDirectoryIdentity] = [:]
    /// Recorded directory paths in creation order.
    private var recorded: [String] = []

    init(root: ProjectPackageWriteRoot, hook: (@Sendable (ProjectPackageWriteStage, String) -> Void)?) {
        self.root = root
        self.hook = hook
    }

    /// Creates one entry (a file when `bytes` is non-nil, otherwise a directory) beneath its verified parent.
    mutating func create(_ path: String, bytes: Data?) throws {
        var components = Self.components(of: path)
        let name = components.removeLast()
        let parent = try openVerifiedChain(components)
        defer { close(parent) }
        hook?(.beforeCreate, path)
        do {
            if let bytes {
                try FileSystem.createFile(at: parent, name, bytes: bytes)
            } else {
                try FileSystem.createDirectory(at: parent, name)
                let opened = try FileSystem.openDestinationDirectory(at: parent, name, matching: nil)
                close(opened.descriptor)
                identities[path] = opened.identity
                recorded.append(path)
            }
        } catch {
            // A parent removed or replaced under the create reports the change, not the create's errno.
            try verifyHeld(parent, components)
            throw error
        }
        hook?(.afterCreate, path)
        try verifyHeld(parent, components)
    }

    /// Final re-walk: every recorded directory, then the destination's name, must still match.
    func verifyComplete() throws {
        for path in recorded {
            let descriptor = try openVerifiedChain(Self.components(of: path))
            close(descriptor)
        }
        try FileSystem.verifyRoot(root)
    }

    /// The held parent must still be the recorded directory, and its name, re-opened from the root,
    /// must still lead to it, so a parent moved away while its descriptor was held is caught.
    private func verifyHeld(_ parent: Int32, _ components: [String]) throws {
        let expected = try components.isEmpty ? root.identity : identity(of: components.joined(separator: "/"))
        guard try ProjectPackageDirectoryIdentity(FileSystem.status(of: parent)) == expected else {
            throw ProjectPackageIOError.destinationChanged
        }
        let reopened = try openVerifiedChain(components)
        close(reopened)
    }

    /// Re-checks the destination's name, then opens `components` beneath the root one no-follow
    /// directory at a time, each matching its recorded identity. The caller closes the result.
    private func openVerifiedChain(_ components: [String]) throws -> Int32 {
        try FileSystem.verifyRoot(root)
        var current = dup(root.descriptor)
        guard current >= 0 else { throw ProjectPackageIOError.system(code: errno) }
        var path = ""
        for component in components {
            path = path.isEmpty ? component : path + "/" + component
            let next: Int32
            do {
                next = try FileSystem.openDestinationDirectory(
                    at: current, component, matching: identity(of: path)
                ).descriptor
            } catch {
                close(current)
                throw error
            }
            close(current)
            current = next
        }
        return current
    }

    private func identity(of path: String) throws -> ProjectPackageDirectoryIdentity {
        guard let identity = identities[path] else { throw ProjectPackageError.missingParent }
        return identity
    }

    private static func components(of path: String) -> [String] {
        path.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
    }
}
