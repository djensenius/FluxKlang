import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private let sinkRunID = "6B1F3D8E-2C4A-4F7B-9E05-1D2C3B4A5F60"
private let sinkSubmissionIssue = "Production access receipt encoding/submission failed"

/// Records attachment submissions, matched Issues and write-seam calls; never mutates the process environment.
private final class SinkSpy: Sendable {
    struct State {
        var attachments: [(json: String, filename: String)] = []
        var submissionIssues = 0
        var issueErrors: [String] = []
        var writeCalls = 0
        var foreign: (path: String, inode: ino_t)?
    }
    let state = Mutex(State())

    func attach(_ json: String, _ filename: String) {
        state.withLock { $0.attachments.append((json, filename)) }
    }
}

/// Requires a zero POSIX result; the call is evaluated outside the expectation macro.
private func succeeded(_ result: Int32) throws {
    let code = errno
    try #require(result == 0, "POSIX call failed: errno \(code)")
}

/// A fresh, owned 0700 directory per test, removed afterwards.
private func withReceiptDirectory(_ body: (String) async throws -> Void) async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("fluxklang-660-\(UUID().uuidString)", isDirectory: false).path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try succeeded(chmod(path, 0o700))
    try await body(path)
}

private func status(_ path: String) throws -> stat {
    var result = stat()
    try succeeded(lstat(path, &result))
    return result
}

private func entries(_ path: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path).sorted()
}

private func environment(directory: String?) -> [String: String] {
    var result = ["FLUXKLANG_AUDIT_RUN_ID": sinkRunID]
    result[ProductionAccessReceiptSink.directoryKey] = directory
    return result
}

/// Run one real test-case scope with the injected environment.
private func runScope(
    _ environment: [String: String],
    spy: SinkSpy,
    fileSystem: ProductionAccessReceiptSink.FileSystem = .init()
) async throws {
    let test = try #require(Test.current)
    let testCase = try #require(Test.Case.current)
    let scope = ProductionAccessScope(
        audit: ProductionAccessAudit(), environment: environment, fileSystem: fileSystem, attach: spy.attach)
    try await scope.provideScope(for: test, testCase: testCase) {}
}

/// Only the scope's existing submission-failure Issue is known; it must occur exactly once.
private func expectingSubmissionIssue(spy: SinkSpy, _ body: () async throws -> Void) async throws {
    try await withKnownIssue("Intentional receipt sink refusal") {
        try await body()
    } matching: { issue in
        guard case .errorCaught = issue.kind, issue.comments == [Comment(rawValue: sinkSubmissionIssue)] else {
            return false
        }
        spy.state.withLock { state in
            state.submissionIssues += 1
            state.issueErrors.append(issue.error.map { String(describing: $0) } ?? "")
        }
        return true
    }
    #expect(spy.state.withLock { $0.submissionIssues } == 1)
}

struct ProductionAccessReceiptSinkTests {
    enum Refusal: CaseIterable, Sendable {
        case empty, relative, missing, regularFile, symlinkedDirectory, symlinkTrailingSlash, symlinkTrailingDot
        case directoryTrailingSlash, groupBits, otherBits, foreignOwner
    }

    /// Hazards injected on the first write of a scope-submitted receipt.
    enum WriteHazard: CaseIterable, Sendable {
        case finalCollision, replacedPartial, missingPartial
    }

    enum Collision: CaseIterable, Sendable {
        case existingFinal, symlinkedFinal, existingPartial
    }

    /// Replacements of the partial after a successful write, or between the source check and the rename.
    enum SourceReplacement: CaseIterable, Sendable {
        case regularFileAfterWrite, symlinkAfterWrite, regularFileBeforeRename
    }

    @Test func keyAbsentUsesTheAttachmentPathUnchanged() async throws {
        let spy = SinkSpy()
        try await runScope(environment(directory: nil), spy: spy)
        let attachments = spy.state.withLock { $0.attachments }
        try #require(attachments.count == 1)
        let receipt = try JSONDecoder().decode(
            ProductionAccessScope.Receipt.self, from: Data(attachments[0].json.utf8))
        #expect(receipt.runID == UUID(uuidString: sinkRunID))
        #expect(attachments[0].filename == "production-access-testCaseExit-\(receipt.invocationID.uuidString).json")
    }

    @Test func keyPresentPublishesOneOwnerOnlyReceiptWithoutAttachment() async throws {
        let test = try #require(Test.current)
        try await withReceiptDirectory { directory in
            let spy = SinkSpy()
            try await runScope(environment(directory: directory), spy: spy)
            #expect(spy.state.withLock { $0.attachments.isEmpty })
            let names = try entries(directory)
            try #require(names.count == 1)
            let path = directory + "/" + names[0]
            let receipt = try JSONDecoder().decode(
                ProductionAccessScope.Receipt.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            #expect(names[0] == "production-access-testCaseExit-\(receipt.invocationID.uuidString).json")
            #expect(receipt.testID == test.id)
            #expect(receipt.runID == UUID(uuidString: sinkRunID))
            let file = try status(path)
            #expect(file.st_mode & S_IFMT == S_IFREG)
            #expect(file.st_mode & 0o777 == 0o600)
        }
    }

    @Test(arguments: Refusal.allCases)
    func invalidDirectoryRecordsIssueAndSubmitsNothing(refusal: Refusal) async throws {
        try await withReceiptDirectory { root in
            let real = root + "/real"
            try succeeded(mkdir(real, 0o700))
            var fileSystem = ProductionAccessReceiptSink.FileSystem()
            let value: String
            switch refusal {
            case .empty: value = ""
            case .relative: value = "relative/receipts"
            case .missing: value = root + "/missing"
            case .regularFile:
                value = root + "/file"
                try #require(FileManager.default.createFile(atPath: value, contents: Data("old".utf8)))
            case .symlinkedDirectory, .symlinkTrailingSlash, .symlinkTrailingDot:
                let link = root + "/link"
                try succeeded(symlink(real, link))
                value = link + (refusal == .symlinkTrailingSlash ? "/" : refusal == .symlinkTrailingDot ? "/." : "")
            case .directoryTrailingSlash: value = real + "/"
            case .groupBits, .otherBits:
                value = real
                try succeeded(chmod(real, refusal == .groupBits ? 0o750 : 0o705))
            case .foreignOwner:
                value = real
                fileSystem.effectiveUserID = { geteuid() &+ 1 }
            }
            let before = try entries(root)
            let spy = SinkSpy()
            try await expectingSubmissionIssue(spy: spy) {
                try await runScope(environment(directory: value), spy: spy, fileSystem: fileSystem)
            }
            #expect(spy.state.withLock { $0.attachments.isEmpty })
            #expect(try entries(root) == before)
            #expect(try entries(real).isEmpty)
        }
    }

    @Test func writeFailureRecordsIssueAndRemovesOnlyItsPartial() async throws {
        try await withReceiptDirectory { directory in
            let spy = SinkSpy()
            var fileSystem = ProductionAccessReceiptSink.FileSystem()
            fileSystem.write = { _, _ in
                spy.state.withLock { $0.writeCalls += 1 }
                errno = EIO
                return -1
            }
            try await expectingSubmissionIssue(spy: spy) {
                try await runScope(environment(directory: directory), spy: spy, fileSystem: fileSystem)
            }
            #expect(spy.state.withLock { $0.writeCalls } == 1)
            #expect(spy.state.withLock { $0.attachments.isEmpty })
            #expect(try entries(directory).isEmpty)
        }
    }

    @Test func shortAndInterruptedWritesPublishVerbatimBytesAtTheNameLimit() async throws {
        try await withReceiptDirectory { directory in
            let spy = SinkSpy()
            var fileSystem = ProductionAccessReceiptSink.FileSystem()
            fileSystem.write = { fileFD, buffer in
                let call = spy.state.withLock { state in
                    state.writeCalls += 1
                    return state.writeCalls
                }
                if call == 1 {
                    errno = EINTR
                    return -1
                }
                return Darwin.write(fileFD, buffer.baseAddress, min(buffer.count, 7))
            }
            let bytes = Data((0..<100).map { UInt8($0) })
            let name = String(repeating: "r", count: ProductionAccessReceiptSink.maximumNameBytes)
            try ProductionAccessReceiptSink(directory: directory, fileSystem: fileSystem).publish(bytes, named: name)
            #expect(spy.state.withLock { $0.writeCalls } == 1 + 15)
            #expect(try entries(directory) == [name])
            #expect(try Data(contentsOf: URL(fileURLWithPath: directory + "/" + name)) == bytes)
        }
    }

    @Test(arguments: [
        "", ".", "..", ".hidden", "a/b", "a\u{0}b",
        String(repeating: "r", count: ProductionAccessReceiptSink.maximumNameBytes + 1)
    ])
    func unsafeFilenameIsRefused(name: String) async throws {
        try await withReceiptDirectory { directory in
            let sink = ProductionAccessReceiptSink(directory: directory)
            let failure = #expect(throws: ProductionAccessReceiptSink.Failure.self) {
                try sink.publish(Data("receipt".utf8), named: name)
            }
            #expect(failure?.description == ProductionAccessReceiptSink.unsafeNameMessage)
            let remaining = try entries(directory)
            #expect(remaining.isEmpty)
        }
    }

    /// The value is split on UTF-8 bytes: a component starting with a combining mark is accepted,
    /// and a combining mark right after the root `/` is still absolute (refused only at lookup).
    @Test func combiningMarkAfterSlashIsSplitOnBytes() async throws {
        try await withReceiptDirectory { root in
            let marked = root + "/\u{301}x"
            try succeeded(mkdir(marked, 0o700))
            try ProductionAccessReceiptSink(directory: marked).publish(Data("receipt".utf8), named: "receipt.json")
            #expect(try entries(marked) == ["receipt.json"])
        }
        let absent = "/\u{301}fluxklang-660-absent-\(UUID().uuidString)"
        let failure = #expect(throws: ProductionAccessReceiptSink.Failure.self) {
            try ProductionAccessReceiptSink(directory: absent).publish(Data("receipt".utf8), named: "receipt.json")
        }
        #expect(failure?.description.hasPrefix("fstatat \(ProductionAccessReceiptSink.directoryKey) failed") == true)
    }

    @Test(arguments: Collision.allCases)
    func collisionIsRefusedWithoutOverwriteOrForeignCleanup(collision: Collision) async throws {
        try await withReceiptDirectory { directory in
            let name = "receipt.json"
            let partial = "." + name + ".partial"
            let existing: String
            switch collision {
            case .existingFinal: existing = name
            case .existingPartial: existing = partial
            case .symlinkedFinal:
                existing = "target"
                try succeeded(symlink(existing, directory + "/" + name))
            }
            let old = Data("old".utf8)
            try #require(FileManager.default.createFile(atPath: directory + "/" + existing, contents: old))
            let before = try entries(directory)
            let identities = try before.map { try status(directory + "/" + $0).st_ino }
            #expect(throws: ProductionAccessReceiptSink.Failure.self) {
                try ProductionAccessReceiptSink(directory: directory).publish(Data("new".utf8), named: name)
            }
            #expect(try entries(directory) == before)
            #expect(try before.map { try status(directory + "/" + $0).st_ino } == identities)
            #expect(try Data(contentsOf: URL(fileURLWithPath: directory + "/" + existing)) == old)
            if collision == .symlinkedFinal {
                #expect(try status(directory + "/" + name).st_mode & S_IFMT == S_IFLNK)
            }
        }
    }

    /// A final-name collision, a replaced partial and a vanished partial all become the scope's
    /// submission Issue, with no attachment fallback and no removal of a file this run did not create.
    @Test(arguments: WriteHazard.allCases)
    func writeTimeHazardBecomesIssueWithoutForeignCleanup(hazard: WriteHazard) async throws {
        try await withReceiptDirectory { directory in
            let spy = SinkSpy()
            let foreignBytes = Data("foreign".utf8)
            var fileSystem = ProductionAccessReceiptSink.FileSystem()
            fileSystem.write = { fileFD, buffer in
                let first = spy.state.withLock { state in
                    state.writeCalls += 1
                    return state.writeCalls == 1
                }
                guard first, let partial = (try? entries(directory))?.first(where: { $0.hasSuffix(".partial") }) else {
                    return Darwin.write(fileFD, buffer.baseAddress, buffer.count)
                }
                let partialPath = directory + "/" + partial
                if hazard != .finalCollision { unlink(partialPath) }
                if hazard != .missingPartial {
                    let foreignPath = hazard == .replacedPartial
                        ? partialPath : directory + "/" + String(partial.dropFirst().dropLast(".partial".count))
                    FileManager.default.createFile(atPath: foreignPath, contents: foreignBytes)
                    let inode = try? status(foreignPath).st_ino
                    spy.state.withLock { state in state.foreign = inode.map { (path: foreignPath, inode: $0) } }
                }
                if hazard == .finalCollision { return Darwin.write(fileFD, buffer.baseAddress, buffer.count) }
                errno = EIO
                return -1
            }
            try await expectingSubmissionIssue(spy: spy) {
                try await runScope(environment(directory: directory), spy: spy, fileSystem: fileSystem)
            }
            #expect(spy.state.withLock { $0.attachments.isEmpty })
            let error = try #require(spy.state.withLock { $0.issueErrors.first })
            switch hazard {
            case .finalCollision: #expect(error.contains("publish production-access-testCaseExit-"))
            case .replacedPartial: #expect(error.contains("not this invocation's file"))
            case .missingPartial: #expect(error.contains("; cleanup fstatat"))
            }
            if hazard == .missingPartial {
                #expect(spy.state.withLock { $0.foreign == nil })
                #expect(try entries(directory).isEmpty)
            } else {
                let survivor = try #require(spy.state.withLock { $0.foreign })
                #expect(try entries(directory) == [(survivor.path as NSString).lastPathComponent])
                #expect(try status(survivor.path).st_ino == survivor.inode)
                #expect(try Data(contentsOf: URL(fileURLWithPath: survivor.path)) == foreignBytes)
            }
        }
    }

    /// `RENAME_EXCL` protects only the destination: a replaced source is refused before the rename,
    /// and a swap inside the check-to-rename window is detected after it. Neither is moved back or deleted.
    @Test(arguments: SourceReplacement.allCases)
    func sourceReplacementIsReportedAndLeftInPlace(replacement: SourceReplacement) async throws {
        try await withReceiptDirectory { directory in
            let spy = SinkSpy()
            let foreignBytes = Data("foreign".utf8)
            let target = directory + "/target"
            // The foreign entry is created while the original still exists, then renamed over the
            // partial, so its inode is necessarily distinct.
            let replace: @Sendable (String) -> Void = { partial in
                let partialPath = directory + "/" + partial
                let staging = directory + "/staging"
                if replacement == .symlinkAfterWrite {
                    FileManager.default.createFile(atPath: target, contents: foreignBytes)
                    symlink(target, staging)
                } else {
                    FileManager.default.createFile(atPath: staging, contents: foreignBytes)
                }
                rename(staging, partialPath)
                let inode = try? status(partialPath).st_ino
                spy.state.withLock { state in state.foreign = inode.map { (path: partialPath, inode: $0) } }
            }
            var fileSystem = ProductionAccessReceiptSink.FileSystem()
            fileSystem.write = { fileFD, buffer in
                let first = spy.state.withLock { state in
                    state.writeCalls += 1
                    return state.writeCalls == 1
                }
                if first, replacement != .regularFileBeforeRename,
                   let partial = (try? entries(directory))?.first(where: { $0.hasSuffix(".partial") }) {
                    replace(partial)
                }
                return Darwin.write(fileFD, buffer.baseAddress, buffer.count)
            }
            if replacement == .regularFileBeforeRename { fileSystem.beforePublish = replace }
            try await expectingSubmissionIssue(spy: spy) {
                try await runScope(environment(directory: directory), spy: spy, fileSystem: fileSystem)
            }
            #expect(spy.state.withLock { $0.attachments.isEmpty })
            let error = try #require(spy.state.withLock { $0.issueErrors.first })
            let foreign = try #require(spy.state.withLock { $0.foreign })
            let names = try entries(directory)
            if replacement == .regularFileBeforeRename {
                // The swapped file was published; it is reported and left under the final name.
                #expect(error.contains("published production-access-testCaseExit-"))
                try #require(names.count == 1)
                #expect(names[0].hasPrefix("production-access-testCaseExit-"))
                let published = directory + "/" + names[0]
                #expect(try status(published).st_ino == foreign.inode)
                #expect(try Data(contentsOf: URL(fileURLWithPath: published)) == foreignBytes)
            } else {
                #expect(error.contains("publish refused: .production-access-testCaseExit-"))
                let partial = (foreign.path as NSString).lastPathComponent
                #expect(names == (replacement == .symlinkAfterWrite ? [partial, "target"] : [partial]))
                #expect(try status(foreign.path).st_ino == foreign.inode)
                #expect(try Data(contentsOf: URL(fileURLWithPath: foreign.path)) == foreignBytes)
                if replacement == .symlinkAfterWrite {
                    #expect(try status(foreign.path).st_mode & S_IFMT == S_IFLNK)
                    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: foreign.path) == target)
                }
            }
            #expect(error.contains("is not this invocation's file; left in place"))
        }
    }
}
