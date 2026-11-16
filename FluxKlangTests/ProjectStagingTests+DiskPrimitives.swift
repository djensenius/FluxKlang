import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `DiskStagingFileSystem` primitives in isolation: repeated listings, record forgetting, the errno map, permission
/// and special-file handling, and byte-keyed identity records. Outcomes are checked with `FileManager`.
extension ProjectStagingTests {
    @Test func diskListingTwiceReturnsSameNames() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let sub = volume.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data([1]).write(to: volume.appendingPathComponent("b"))
        try Data([2]).write(to: volume.appendingPathComponent("a"))
        try Data([3]).write(to: sub.appendingPathComponent("y"))
        try Data([4]).write(to: sub.appendingPathComponent("x"))
        let disk = try Self.disk(volume)

        let expectedRoot = try Self.diskNames(volume)
        let expectedSub = try Self.diskNames(sub)
        #expect(expectedRoot == ["a", "b", "sub"])
        #expect(expectedSub == ["x", "y"])
        for pass in 1...3 {
            #expect(try disk.listDirectory(at: "", limit: 8).sorted() == expectedRoot, "root pass \(pass)")
            #expect(try disk.listDirectory(at: "sub", limit: 8).sorted() == expectedSub, "sub pass \(pass)")
        }
    }

    @Test func diskRenameAndRemoveTreeForgetRecords() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let disk = try Self.disk(volume)

        try disk.makeDirectory(at: "s")
        try disk.makeDirectory(at: "s/inner")
        try disk.rename(from: "s", to: "d")
        #expect(try disk.status(at: "s") == nil)
        #expect(try disk.status(at: "s/inner") == nil)
        try disk.makeDirectory(at: "s")
        #expect(try Self.diskNames(volume) == ["d", "s"])
        #expect(try Self.diskNames(volume.appendingPathComponent("d")) == ["inner"])

        try disk.makeDirectory(at: "x")
        try disk.removeTree(at: "x")
        #expect(try disk.status(at: "x") == nil)
        try disk.makeDirectory(at: "x")
        #expect(try Self.diskNames(volume) == ["d", "s", "x"])

        // Forgetting "a" must not drop the record of its byte-prefix sibling "ab".
        try disk.makeDirectory(at: "a")
        try disk.makeDirectory(at: "ab")
        try disk.rename(from: "a", to: "c")
        let sibling = volume.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.removeItem(at: sibling)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        #expect(throws: StagingIOFault.changed) { try disk.status(at: "ab") }
    }

    @Test func diskErrnoMap() {
        let expected: [(code: Int32, fault: StagingIOFault)] = [
            (ENOSPC, .noSpace), (EDQUOT, .noSpace),
            (EACCES, .denied), (EPERM, .denied), (EROFS, .denied),
            (EEXIST, .exists), (ENOTEMPTY, .exists),
            (ENOENT, .notFound), (EXDEV, .crossVolume),
            (EINTR, .ioError), (EIO, .ioError), (EBADF, .ioError)
        ]
        for (code, fault) in expected {
            #expect(DiskStagingFileSystem.fault(errno: code) == fault, "errno \(code)")
        }
        for code in Int32(0)...Int32(256) {
            #expect(DiskStagingFileSystem.fault(errno: code) != .interrupted, "errno \(code)")
        }
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores permission bits"))
    func diskReadOnlyDirectoryIsDenied() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let locked = volume.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let disk = try Self.disk(volume)

        #expect(throws: StagingIOFault.denied) { try disk.makeDirectory(at: "ro/x") }
        #expect(throws: StagingIOFault.denied) { try disk.createFile(at: "ro/f", bytes: Data([1])) }
        #expect(try Self.diskNames(locked).isEmpty)
    }

    @Test func diskFifoIsUnsupportedAndUnreadable() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        try #require(mkfifo(volume.appendingPathComponent("p").path, 0o600) == 0)
        let disk = try Self.disk(volume)

        let status = try #require(try disk.status(at: "p"))
        #expect(status.kind == .unsupported)
        #expect(status.byteCount == 0)
        #expect(throws: StagingIOFault.notFound) { try disk.read(at: "p", offset: 0, count: 1) }
        #expect(try Self.diskNames(volume) == ["p"])
    }

    @Test func diskIdentityRecordsAreKeyedByBytes() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let composed = "\u{E9}"
        let decomposed = "e\u{301}"
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        let disk = try Self.disk(volume)

        try disk.makeDirectory(at: composed)
        // Replace the recorded directory behind the adapter's back.
        let url = volume.appendingPathComponent(composed, isDirectory: true)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        #expect(throws: StagingIOFault.changed) { try disk.status(at: composed) }
        // The decomposed spelling was never recorded, so it must not be checked against the composed record:
        // whatever the volume resolves it to, it is not `.changed`.
        let alias = try disk.status(at: decomposed)
        #expect(alias == nil || alias?.kind == .directory)
        #expect(try Self.diskNames(volume).count == 1)
    }
}
