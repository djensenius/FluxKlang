import Foundation

/// Bounded, descriptor-relative reader for a directory package. Each call makes one P1 attempt:
/// every request is bounded before IO, each delivered chunk is charged once before it is retained,
/// a zero allowance probes for one more byte instead of assuming EOF, and a file finishes only after
/// an actual zero-byte read. Symbolic links, special files, hard-linked files and mount-point crossings
/// refuse, and a member that changes while open refuses. Declarations are never preallocated.
/// Only the manifest is decoded; all other member bytes are retained as read. This is not a document
/// decoder, migration, bookmark resolver, file coordinator or activation authority.
struct ProjectPackageReader: Sendable {
    let policy: ProjectPackageManifestPolicy
    /// Upper bound for one read request and for the reusable read buffer.
    let chunkByteCount: Int
    /// Test observation point after each retained chunk (path, bytes retained so far); nil in production.
    var chunkHookForTesting: (@Sendable (String, Int) -> Void)?
    /// Test interleaving point after a member's pre-open placement check and before `openat` (path);
    /// nil in production. Lets tests mutate the filesystem between admission and open deterministically.
    var openHookForTesting: (@Sendable (String) -> Void)?

    init(policy: ProjectPackageManifestPolicy, chunkByteCount: Int = 65_536) throws(ProjectPackageError) {
        guard chunkByteCount > 0 else { throw .invalidLimits }
        self.policy = policy
        self.chunkByteCount = chunkByteCount
    }

    func read(from root: URL) throws -> ProjectPackageContents {
        let descriptor = try ProjectPackageFileSystem.openRoot(root)
        defer { close(descriptor) }
        var session = ProjectPackageReadSession(reader: self)
        return try ProjectPackageContents(reading: session.read(root: descriptor))
    }
}

/// Minted only in this file, after the reader's single P1 attempt admitted exactly these entries.
struct ProjectPackageReadProof: Sendable {
    let manifest: ProjectPackageManifest
    let manifestBytes: Data
    let directories: [String]
    let files: [String: Data]
    let limits: ProjectPackageLimits

    fileprivate init(
        manifest: ProjectPackageManifest, manifestBytes: Data, directories: [String], files: [String: Data],
        limits: ProjectPackageLimits
    ) {
        self.manifest = manifest
        self.manifestBytes = manifestBytes
        self.directories = directories
        self.files = files
        self.limits = limits
    }
}

private struct ProjectPackageReadSession {
    private typealias FileSystem = ProjectPackageFileSystem

    let reader: ProjectPackageReader
    private var admission: ProjectPackageAdmission
    private var buffer: [UInt8]
    private var rootDevice: dev_t = 0
    private var declared: [String: Int] = [:]
    private var directories: [String] = []
    private var files: [String: Data] = [:]

    private var policy: ProjectPackageManifestPolicy { reader.policy }

    init(reader: ProjectPackageReader) {
        self.reader = reader
        admission = ProjectPackageAdmission(limits: reader.policy.packageLimits)
        // The EOF probe needs one byte even when every member allowance is zero.
        let entryBytes = reader.policy.packageLimits.maxEntryBytes
        buffer = [UInt8](repeating: 0, count: min(reader.chunkByteCount, max(entryBytes, 1)))
    }

    mutating func read(root: Int32) throws -> ProjectPackageReadProof {
        rootDevice = try FileSystem.status(of: root).st_dev
        let manifestBytes = try readManifest(root: root)
        let manifest = try ProjectPackageManifest.decode(from: manifestBytes, policy: policy)
        declared = manifest.declaredMemberByteCounts
        try visit(directory: root, prefix: nil)
        try admission.validateComplete()
        return ProjectPackageReadProof(
            manifest: manifest, manifestBytes: manifestBytes, directories: directories, files: files,
            limits: policy.packageLimits
        )
    }

    private mutating func readManifest(root: Int32) throws -> Data {
        let name = ProjectPackageManifest.manifestMemberPath
        let info: stat
        do {
            info = try FileSystem.status(at: root, name)
        } catch ProjectPackageIOError.system(code: ENOENT) {
            throw ProjectPackageIOError.missingMember
        }
        let kind = FileSystem.kind(info)
        try admission.admit(path: name, kind: kind)
        guard kind == .regularFile else { throw ProjectPackageIOError.missingMember }
        let opened = try open(at: root, name, path: name, admitted: info)
        defer { close(opened.descriptor) }
        return try readFile(opened, path: name, cap: policy.maxManifestBytes)
    }

    private mutating func visit(directory: Int32, prefix: String?) throws {
        // The already-admitted root manifest is listed again but not re-admitted.
        let listed = prefix == nil ? 1 : 0
        let limit = policy.packageLimits.maxEntries - admission.entryCount + listed
        for name in try FileSystem.names(in: directory, limit: limit) {
            if prefix == nil, name == ProjectPackageManifest.manifestMemberPath { continue }
            let path = prefix.map { "\($0)/\(name)" } ?? name
            let info = try FileSystem.status(at: directory, name)
            let kind = FileSystem.kind(info)
            // Lexical, limit, kind, link-count and device refusal happen before the member is opened.
            try admission.admit(path: path, kind: kind, declaredByteCount: kind == .directory ? nil : declared[path])
            let opened = try open(at: directory, name, path: path, admitted: info)
            defer { close(opened.descriptor) }
            if kind == .directory {
                directories.append(path)
                try visit(directory: opened.descriptor, prefix: path)
            } else {
                files[path] = try readFile(opened, path: path, cap: nil)
            }
        }
    }

    /// Placement is checked on the admitted status and again on the opened descriptor's status, so a
    /// link or mount change between admission and open cannot become the change-detection baseline.
    private func open(
        at directory: Int32, _ name: String, path: String, admitted info: stat
    ) throws -> (descriptor: Int32, status: stat) {
        try checkPlacement(info)
        reader.openHookForTesting?(path)
        let opened = try FileSystem.openMember(at: directory, name, matching: info)
        do {
            try checkPlacement(opened.status)
        } catch {
            close(opened.descriptor)
            throw error
        }
        return opened
    }

    private func checkPlacement(_ info: stat) throws {
        guard info.st_dev == rootDevice else { throw ProjectPackageIOError.crossedMountPoint }
        if FileSystem.kind(info) == .regularFile, info.st_nlink > 1 {
            throw ProjectPackageIOError.hardLinkedMember
        }
    }

    private mutating func readFile(
        _ opened: (descriptor: Int32, status: stat), path: String, cap: Int?
    ) throws -> Data {
        var bytes = Data()
        while true {
            var request = min(reader.chunkByteCount, admission.remainingReadableBytes)
            if let cap { request = min(request, cap - bytes.count) }
            // A zero allowance is not EOF: probe for one byte so an over-long member is refused.
            request = max(request, 1)
            let delivered = try FileSystem.readChunk(opened.descriptor, into: &buffer, count: request)
            guard delivered > 0 else { break }
            try admission.consume(byteCount: delivered)
            if let cap, delivered > cap - bytes.count { throw ProjectPackageManifestError.manifestBytesExceeded }
            bytes.append(contentsOf: buffer[..<delivered])
            reader.chunkHookForTesting?(path, bytes.count)
        }
        // Real EOF reached; the member must be unchanged since it was opened.
        let final = try FileSystem.status(of: opened.descriptor)
        guard FileSystem.sameContentState(opened.status, final), final.st_size == bytes.count else {
            throw ProjectPackageIOError.memberChanged
        }
        try admission.finishFile()
        return bytes
    }
}
