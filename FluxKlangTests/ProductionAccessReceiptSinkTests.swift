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
        var writeCalls = 0
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
    let path = NSTemporaryDirectory() + "fluxklang-660-\(UUID().uuidString)"
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
        spy.state.withLock { $0.submissionIssues += 1 }
        return true
    }
    #expect(spy.state.withLock { $0.submissionIssues } == 1)
}

struct ProductionAccessReceiptSinkTests {
    enum Refusal: CaseIterable, Sendable {
        case empty, relative, missing, regularFile, symlinkedDirectory, groupBits, otherBits, foreignOwner
    }

    enum Collision: CaseIterable, Sendable {
        case existingFinal, symlinkedFinal, existingPartial
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
            case .symlinkedDirectory:
                value = root + "/link"
                try succeeded(symlink(real, value))
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
            #expect(throws: ProductionAccessReceiptSink.Failure.self) {
                try sink.publish(Data("receipt".utf8), named: name)
            }
            #expect(try entries(directory).isEmpty)
        }
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
}
