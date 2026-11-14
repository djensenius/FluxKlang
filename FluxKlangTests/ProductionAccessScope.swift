import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Cumulative exit evidence only: not success, descendant coverage, or process quiescence.
struct ProductionAccessScope: SuiteTrait, TestTrait, TestScoping {
    enum ScopeKind: String, Codable, Sendable {
        case suiteExit, testCaseExit
    }

    struct Counts: Codable, Sendable {
        let operationID: Int
        let factoryEvaluated: UInt64
        let apiEntered: UInt64
    }

    struct Receipt: Codable, Sendable {
        let schemaVersion: Int
        let scopeKind: ScopeKind
        let testID: Test.ID
        let runID: UUID
        let processInstanceID: UUID
        let processID: Int32
        let invocationID: UUID
        let counts: [Counts]
    }

    private static let processInstanceID = UUID()
    private let audit: ProductionAccessAudit
    private let runID: String?
    private let submit: @Sendable (String, String) throws -> Void

    var isRecursive: Bool { false }

    init() {
        self.init(audit: .shared, environment: ProcessInfo.processInfo.environment)
    }

    /// Transport-selection seam (#660). Without `FLUXKLANG_AUDIT_RECEIPT_DIR`, receipts go to
    /// `attach` unchanged. With the key present (any value), only the file sink is used.
    init(
        audit: ProductionAccessAudit,
        environment: [String: String],
        fileSystem: ProductionAccessReceiptSink.FileSystem = .init(),
        attach: @escaping @Sendable (String, String) -> Void = { json, filename in
            // Void/best-effort: this is not a persistence or delivery acknowledgment.
            Attachment.record(json, named: filename)
        }
    ) {
        let submit: @Sendable (String, String) throws -> Void
        if let directory = environment[ProductionAccessReceiptSink.directoryKey] {
            let sink = ProductionAccessReceiptSink(directory: directory, fileSystem: fileSystem)
            submit = { json, filename in try sink.publish(Data(json.utf8), named: filename) }
        } else {
            submit = attach
        }
        self.init(audit: audit, runID: environment["FLUXKLANG_AUDIT_RUN_ID"], submit: submit)
    }

    /// Private-audit and local submission-failure seams for this helper's pure tests.
    init(
        audit: ProductionAccessAudit,
        runID: String?,
        submit: @escaping @Sendable (String, String) throws -> Void
    ) {
        self.audit = audit
        self.runID = runID
        self.submit = submit
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let invocationID = UUID()
        defer {
            // Exactly one coherent, absolute snapshot, even on error or cancellation.
            let snapshot = audit.snapshot()
            recordExit(snapshot, test: test, testCase: testCase, invocationID: invocationID)
        }
        try await function()
    }

    private func recordExit(
        _ snapshot: ProductionAccessAudit.Snapshot,
        test: Test,
        testCase: Test.Case?,
        invocationID: UUID
    ) {
        let counts = ProductionAccessAudit.Operation.allCases.map { operation in
            let factory = snapshot.count(.factoryEvaluated, for: operation)
            let api = snapshot.count(.apiEntered, for: operation)
            if factory != 0 || api != 0 {
                Issue.record(
                    "Production access operation \(operation.rawValue): factoryEvaluated=\(factory), apiEntered=\(api)")
            }
            return Counts(operationID: operation.rawValue, factoryEvaluated: factory, apiEntered: api)
        }

        let scopeKind: ScopeKind?
        switch (test.isSuite, testCase != nil) {
        case (true, false): scopeKind = .suiteExit
        case (false, true): scopeKind = .testCaseExit
        default:
            scopeKind = nil
            Issue.record("Production access scope has invalid test/case context")
        }
        let parsedRunID = runID.flatMap(UUID.init(uuidString:))
        if parsedRunID == nil {
            Issue.record("Production access scope requires FLUXKLANG_AUDIT_RUN_ID to be a UUID")
        }
        guard let scopeKind, let parsedRunID else { return }

        let receipt = Receipt(
            schemaVersion: 1,
            scopeKind: scopeKind,
            testID: test.id,
            runID: parsedRunID,
            processInstanceID: Self.processInstanceID,
            processID: ProcessInfo.processInfo.processIdentifier,
            invocationID: invocationID,
            counts: counts)
        do {
            let data = try JSONEncoder().encode(receipt)
            guard let json = String(data: data, encoding: .utf8) else {
                Issue.record("Production access receipt encoding/submission failed")
                return
            }
            try submit(json, "production-access-\(scopeKind.rawValue)-\(invocationID.uuidString).json")
        } catch {
            Issue.record(error, "Production access receipt encoding/submission failed")
        }
    }
}

extension Trait where Self == ProductionAccessScope {
    static var productionAccessAudit: Self { Self() }
}

/// Test-only receipt file transport (#660), selected only by `FLUXKLANG_AUDIT_RECEIPT_DIR`.
/// Not a production transport, and not retention or quiescence evidence. The directory is
/// never created; every file operation is relative to its validated descriptor. Only the final
/// path component must not be a symlink; parents resolve normally (e.g. /var -> /private/var).
struct ProductionAccessReceiptSink: Sendable {
    static let directoryKey = "FLUXKLANG_AUDIT_RECEIPT_DIR"
    /// Keeps `.<name>.partial` within the 255-byte component limit.
    static let maximumNameBytes = 246
    static let unsafeNameMessage = "Receipt filename must be one safe path component"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Ownership and write seams for pure tests; the defaults are the real POSIX calls.
    struct FileSystem: Sendable {
        var effectiveUserID: @Sendable () -> uid_t = { geteuid() }
        /// Returns the `write(2)` result, leaving `errno` set on failure.
        var write: @Sendable (Int32, UnsafeRawBufferPointer) -> Int = { Darwin.write($0, $1.baseAddress, $1.count) }
    }

    let directory: String
    var fileSystem = FileSystem()

    func publish(_ bytes: Data, named name: String) throws {
        try Self.validate(name: name)
        let directoryFD = try openDirectory()
        defer { close(directoryFD) }
        let partial = ".\(name).partial"
        let fileFD = openat(directoryFD, partial, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else {
            let code = errno
            throw Self.posixFailure("exclusive-create \(partial)", code: code)
        }
        // This invocation created the partial; it alone is removed on failure, until publication.
        // If fstat fails here, the partial's identity is unverified, so it is left behind and reported.
        var created = stat()
        guard fstat(fileFD, &created) == 0 else {
            let code = errno
            close(fileFD)
            throw Failure(description: "\(Self.posixFailure("fstat \(partial)", code: code)); cleanup left unverified")
        }
        do {
            try writeAll(bytes, to: fileFD)
            guard fsync(fileFD) == 0 else {
                let code = errno
                throw Self.posixFailure("fsync \(partial)", code: code)
            }
        } catch {
            close(fileFD)
            throw Self.remove(partial, in: directoryFD, created: created, after: error)
        }
        guard close(fileFD) == 0 else {
            let code = errno
            let failure = Self.posixFailure("close \(partial)", code: code)
            throw Self.remove(partial, in: directoryFD, created: created, after: failure)
        }
        guard renameatx_np(directoryFD, partial, directoryFD, name, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            let failure = Self.posixFailure("publish \(name)", code: code)
            throw Self.remove(partial, in: directoryFD, created: created, after: failure)
        }
    }

    private static func validate(name: String) throws {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumNameBytes, bytes.first != UInt8(ascii: "."),
              !bytes.contains(UInt8(ascii: "/")), !bytes.contains(0) else {
            throw Failure(description: unsafeNameMessage)
        }
    }

    /// Opens the parent (ancestors resolve normally), then inspects and opens the final component
    /// relative to it without following a symlink. A trailing `/`, `.` or `..` is refused, because
    /// it would make path resolution follow a final symlink.
    private func openDirectory() throws -> Int32 {
        let key = Self.directoryKey
        guard directory.hasPrefix("/"), let separator = directory.lastIndex(of: "/") else {
            throw Failure(description: "\(key) must be a non-empty absolute path")
        }
        let name = String(directory[directory.index(after: separator)...])
        guard !name.isEmpty, name != ".", name != ".." else {
            throw Failure(description: "\(key) must not end in /, . or ..")
        }
        let parentPath = separator == directory.startIndex ? "/" : String(directory[..<separator])
        let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            let code = errno
            throw Self.posixFailure("open parent of \(key)", code: code)
        }
        defer { close(parentFD) }
        var pathStatus = stat()
        guard fstatat(parentFD, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            throw Self.posixFailure("fstatat \(key)", code: code)
        }
        guard pathStatus.st_mode & S_IFMT == S_IFDIR else {
            throw Failure(description: "\(key) must be a real directory, not a symlink or file")
        }
        try checkOwnerAndMode(pathStatus)
        let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            let code = errno
            throw Self.posixFailure("open \(key)", code: code)
        }
        do {
            var openedStatus = stat()
            guard fstat(directoryFD, &openedStatus) == 0 else {
                let code = errno
                throw Self.posixFailure("fstat \(key)", code: code)
            }
            guard openedStatus.st_mode & S_IFMT == S_IFDIR, openedStatus.st_dev == pathStatus.st_dev,
                  openedStatus.st_ino == pathStatus.st_ino else {
                throw Failure(description: "\(Self.directoryKey) changed while it was opened")
            }
            try checkOwnerAndMode(openedStatus)
        } catch {
            close(directoryFD)
            throw error
        }
        return directoryFD
    }

    private func checkOwnerAndMode(_ status: stat) throws {
        guard status.st_uid == fileSystem.effectiveUserID() else {
            throw Failure(description: "\(Self.directoryKey) must be owned by the effective user")
        }
        guard status.st_mode & 0o077 == 0 else {
            throw Failure(description: "\(Self.directoryKey) must have no group or other permission bits")
        }
    }

    private func writeAll(_ bytes: Data, to fileFD: Int32) throws {
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = fileSystem.write(fileFD, UnsafeRawBufferPointer(rebasing: buffer[offset...]))
                let code = errno
                if written < 0 && code == EINTR { continue }
                guard written >= 0 else { throw Self.posixFailure("write", code: code) }
                guard written > 0, written <= buffer.count - offset else {
                    throw Failure(description: "write returned \(written) bytes")
                }
                offset += written
            }
        }
    }

    /// Removes only this invocation's unpublished partial; cleanup failure joins the thrown error.
    private static func remove(_ partial: String, in directoryFD: Int32, created: stat, after error: Error) -> Error {
        var current = stat()
        guard fstatat(directoryFD, partial, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return Failure(description: "\(error); cleanup \(posixFailure("fstatat \(partial)", code: code))")
        }
        guard current.st_dev == created.st_dev, current.st_ino == created.st_ino else {
            return Failure(description: "\(error); cleanup left \(partial): not this invocation's file")
        }
        guard unlinkat(directoryFD, partial, 0) == 0 else {
            let code = errno
            return Failure(description: "\(error); cleanup \(posixFailure("unlinkat \(partial)", code: code))")
        }
        return error
    }

    /// `code` must be captured from `errno` immediately after the failing call.
    private static func posixFailure(_ operation: String, code: Int32) -> Failure {
        return Failure(description: "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))")
    }
}
