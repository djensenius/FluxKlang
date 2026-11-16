import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The staging pipeline over `DiskStagingFileSystem` in a per-test temporary directory. Outcomes are checked with the
/// P3 reader and `FileManager`, never through the adapter under test.
extension ProjectStagingTests {
    static func diskScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStagingDiskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: diskVolume(url), withIntermediateDirectories: false)
        return url
    }

    static func diskVolume(_ scratch: URL) -> URL {
        scratch.appendingPathComponent("vol", isDirectory: true)
    }

    static func disk(_ volume: URL, limits: ProjectPackageLimits? = nil) throws -> DiskStagingFileSystem {
        try DiskStagingFileSystem(root: volume, limits: limits ?? Fixture.limits())
    }

    static func diskNames(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private static func diskExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func diskRead(_ url: URL) throws -> ProjectPackageContents {
        try ProjectPackageReader(policy: Fixture.policy(), chunkByteCount: 7).read(from: url)
    }

    private static func onDisk<Value>(
        _ body: () throws(StagingRefusal) -> Value
    ) -> Result<Value, StagingRefusal> {
        do throws(StagingRefusal) {
            return try .success(body())
        } catch {
            return .failure(error)
        }
    }

    private static func diskExport(
        _ plan: StagingPlan, _ contents: ProjectPackageContents, _ disk: inout DiskStagingFileSystem
    ) -> Result<StagingReceipt, StagingRefusal> {
        onDisk { () throws(StagingRefusal) in try StagedPackageExport.run(plan: plan, contents: contents, in: &disk) }
    }

    /// Fires `mutate` once, at the first `operation` on `path`.
    private static func hook(
        _ disk: DiskStagingFileSystem, at operation: DiskStagingOperation, of path: String,
        mutate: @escaping () -> Void
    ) {
        var fired = false
        disk.operationHookForTesting = { observed, observedPath in
            guard !fired, observed == operation, observedPath == path else { return }
            fired = true
            mutate()
        }
    }

    // MARK: Pipeline round trips

    @Test func diskCreateNewExportRoundTrips() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        var disk = try Self.disk(volume)
        let contents = try Fixture.big("new")
        let result = Self.diskExport(try Fixture.plan(.createNew), contents, &disk)
        #expect(Fixture.value(result) == StagingReceipt(mode: .createNew, backupRetained: false))
        #expect(try Self.diskRead(volume.appendingPathComponent(Fixture.destination)) == contents)
        #expect(try Self.diskNames(volume) == [Fixture.destination])
    }

    @Test func diskReplaceExistingSwapsAndRemovesBackup() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let destination = volume.appendingPathComponent(Fixture.destination)
        try ProjectPackageWriter.write(Fixture.tiny("old"), to: destination)
        var disk = try Self.disk(volume)
        let contents = try Fixture.big("new")
        let result = Self.diskExport(try Fixture.plan(.replaceExisting), contents, &disk)
        #expect(Fixture.value(result) == StagingReceipt(mode: .replaceExisting, backupRetained: false))
        #expect(try Self.diskRead(destination) == contents)
        #expect(try Self.diskNames(volume) == [Fixture.destination])
    }

    @Test func diskCreateNewRefusesExistingWithoutMutation() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let destination = volume.appendingPathComponent(Fixture.destination)
        let old = try Fixture.tiny("old")
        try ProjectPackageWriter.write(old, to: destination)
        var disk = try Self.disk(volume)
        var operations: [DiskStagingOperation] = []
        disk.operationHookForTesting = { operation, _ in operations.append(operation) }
        let result = Self.diskExport(try Fixture.plan(.createNew), try Fixture.big("new"), &disk)
        #expect(Fixture.refusal(result) == .destinationExists)
        #expect(!operations.isEmpty)
        #expect(operations.allSatisfy { $0 == .status })
        #expect(try Self.diskRead(destination) == old)
        #expect(try Self.diskNames(volume) == [Fixture.destination])
    }

    @Test func diskImportCopiesSourceUnchanged() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let source = try Fixture.big("src")
        try ProjectPackageWriter.write(source, to: volume.appendingPathComponent(Fixture.source))
        var disk = try Self.disk(volume)
        let plan = try Fixture.plan(.createNew)
        let policy = try Fixture.policy()
        let result = Self.onDisk { () throws(StagingRefusal) in
            try StagedPackageImport.run(
                from: Fixture.source, plan: plan, policy: policy, chunkByteCount: 3, in: &disk
            )
        }
        #expect(Fixture.value(result) == StagingReceipt(mode: .createNew, backupRetained: false))
        #expect(try Self.diskRead(volume.appendingPathComponent(Fixture.destination)) == source)
        #expect(try Self.diskRead(volume.appendingPathComponent(Fixture.source)) == source)
        #expect(try Self.diskNames(volume) == [Fixture.destination, Fixture.source])
    }

    @Test func diskRecoveryRestoresBackup() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let old = try Fixture.tiny("old")
        // Crash residue between the retire and promote renames: a backup, a staging tree, no destination.
        try ProjectPackageWriter.write(old, to: volume.appendingPathComponent(Fixture.backup))
        let staging = volume.appendingPathComponent(Fixture.staging)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("graphs"), withIntermediateDirectories: true
        )
        try Data("{\"partial".utf8).write(to: staging.appendingPathComponent("manifest.json"))
        var disk = try Self.disk(volume)
        let plan = try Fixture.plan(.replaceExisting)
        let result = Self.onDisk { () throws(StagingRefusal) in try StagingRecovery.recover(plan: plan, in: &disk) }
        #expect(Fixture.value(result) == [.restoredPrevious, .removedStaging])
        #expect(try Self.diskRead(volume.appendingPathComponent(Fixture.destination)) == old)
        #expect(try Self.diskNames(volume) == [Fixture.destination])
    }

    // MARK: Concurrent mutation

    @Test func stagingSubdirectoryReplacedIsRefused() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let graphs = volume.appendingPathComponent(Fixture.staging).appendingPathComponent("graphs")
        let aside = scratch.appendingPathComponent("aside")
        var disk = try Self.disk(volume)
        Self.hook(disk, at: .createFile, of: Fixture.staging + "/graphs/main.json") {
            #expect(rename(graphs.path, aside.path) == 0)
            #expect(mkdir(graphs.path, 0o755) == 0)
        }
        let result = Self.diskExport(try Fixture.plan(.createNew), try Fixture.big("new"), &disk)
        #expect(Fixture.refusal(result) == .ioFailed(step: .writeEntry, fault: .changed, cleanup: .removed))
        #expect(try Self.diskNames(aside).isEmpty)
        #expect(try Self.diskNames(volume).isEmpty)
    }

    @Test func stagingSubdirectorySwappedForSymlinkIsRefused() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let graphs = volume.appendingPathComponent(Fixture.staging).appendingPathComponent("graphs")
        let aside = scratch.appendingPathComponent("aside")
        let outside = scratch.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        var disk = try Self.disk(volume)
        Self.hook(disk, at: .createFile, of: Fixture.staging + "/graphs/main.json") {
            #expect(rename(graphs.path, aside.path) == 0)
            #expect(symlink(outside.path, graphs.path) == 0)
        }
        let result = Self.diskExport(try Fixture.plan(.createNew), try Fixture.big("new"), &disk)
        #expect(Fixture.refusal(result) == .ioFailed(step: .writeEntry, fault: .changed, cleanup: .removed))
        // The link was unlinked by cleanup, never followed: its target survives, still empty.
        #expect(try Self.diskNames(outside).isEmpty)
        #expect(try Self.diskNames(aside).isEmpty)
        #expect(try Self.diskNames(volume).isEmpty)
    }

    @Test func replacedVolumeRootIsRefused() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let renamed = scratch.appendingPathComponent("vol-old")
        var disk = try Self.disk(volume)
        Self.hook(disk, at: .createFile, of: Fixture.staging + "/graphs/main.json") {
            #expect(rename(volume.path, renamed.path) == 0)
            #expect(mkdir(volume.path, 0o755) == 0)
        }
        let result = Self.diskExport(try Fixture.plan(.createNew), try Fixture.big("new"), &disk)
        #expect(Fixture.refusal(result) == .ioFailed(step: .writeEntry, fault: .changed, cleanup: .leftBehind))
        #expect(try Self.diskNames(volume).isEmpty)
        // Residue: the staging tree written before the swap stays in the renamed root.
        #expect(try Self.diskNames(renamed) == [Fixture.staging])
        #expect(throws: StagingIOFault.changed) { try disk.status(at: "") }
    }

    @Test func cleanupNeverRemovesImpostorStagingRoot() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let staging = volume.appendingPathComponent(Fixture.staging)
        let sentinel = staging.appendingPathComponent("sentinel")
        let aside = scratch.appendingPathComponent("aside")
        var disk = try Self.disk(volume)
        Self.hook(disk, at: .createFile, of: Fixture.staging + "/graphs/main.json") {
            #expect(rename(staging.path, aside.path) == 0)
            #expect(mkdir(staging.path, 0o755) == 0)
            #expect(FileManager.default.createFile(atPath: sentinel.path, contents: Data([7])))
        }
        let result = Self.diskExport(try Fixture.plan(.createNew), try Fixture.big("new"), &disk)
        #expect(Fixture.refusal(result) == .ioFailed(step: .writeEntry, fault: .changed, cleanup: .leftBehind))
        #expect(throws: StagingIOFault.changed) { try disk.removeTree(at: Fixture.staging) }
        #expect(try Data(contentsOf: sentinel) == Data([7]))
        #expect(try Self.diskNames(staging) == ["sentinel"])
        #expect(try Self.diskNames(aside).contains("manifest.json"))
    }

    // MARK: Primitives

    @Test func removeTreeIsNoFollowAndTwoPhase() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let manager = FileManager.default
        let outside = scratch.appendingPathComponent("outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data([1]).write(to: outside.appendingPathComponent("keep"))
        // 6 nodes beneath "big" against a budget of maxEntries + 1 = 4, spread so no single listing exceeds it.
        for path in ["big/a/x1", "big/a/x2", "big/b/y1", "big/b/y2", "deep/a/b/c", "tree/sub/file"] {
            let url = volume.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([2]).write(to: url)
        }
        try manager.createSymbolicLink(at: volume.appendingPathComponent("tree/link"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: volume.appendingPathComponent("toplink"), withDestinationURL: outside)
        let disk = try Self.disk(volume, limits: Fixture.limits(entries: 3, depth: 2))

        #expect(throws: StagingIOFault.tooManyEntries) { try disk.removeTree(at: "big") }
        #expect(try Self.diskNames(volume.appendingPathComponent("big/a")) == ["x1", "x2"])
        #expect(try Self.diskNames(volume.appendingPathComponent("big/b")) == ["y1", "y2"])
        #expect(throws: StagingIOFault.tooManyEntries) { try disk.removeTree(at: "deep") }
        #expect(Self.diskExists(volume.appendingPathComponent("deep/a/b/c")))

        try disk.removeTree(at: "tree")
        try disk.removeTree(at: "toplink")
        #expect(try Self.diskNames(volume) == ["big", "deep"])
        #expect(try Self.diskNames(outside) == ["keep"])
        #expect(throws: StagingIOFault.notFound) { try disk.removeTree(at: "tree") }
    }

    @Test func statusClassifiesLinksAndAbsence() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let manager = FileManager.default
        try manager.createDirectory(at: volume.appendingPathComponent("d"), withIntermediateDirectories: false)
        try Data("abc".utf8).write(to: volume.appendingPathComponent("f"))
        try manager.createSymbolicLink(atPath: volume.appendingPathComponent("l").path, withDestinationPath: "d")
        try manager.createSymbolicLink(atPath: volume.appendingPathComponent("x").path, withDestinationPath: "none")
        let disk = try Self.disk(volume)

        let expected: [(name: String, status: (kind: ProjectPackageEntryKind, size: Int))] = [
            ("d", (.directory, 0)), ("f", (.regularFile, 3)), ("l", (.symbolicLink, 0)), ("x", (.symbolicLink, 0))
        ]
        for (name, (kind, size)) in expected {
            let status = try #require(try disk.status(at: name), "\(name)")
            let attributes = try manager.attributesOfItem(atPath: volume.appendingPathComponent(name).path)
            let device = try #require(attributes[.systemNumber] as? NSNumber, "\(name)")
            let inode = try #require(attributes[.systemFileNumber] as? NSNumber, "\(name)")
            #expect(status.kind == kind, "\(name)")
            #expect(status.byteCount == size, "\(name)")
            #expect(status.volume == device.intValue, "\(name)")
            #expect(status.identity == inode.uint64Value, "\(name)")
        }
        #expect(try disk.status(at: "")?.kind == .directory)
        for absent in ["missing", "missing/y", "f/y"] {
            #expect(try disk.status(at: absent) == nil, "\(absent)")
            #expect(throws: StagingIOFault.notFound, "\(absent)") { try disk.read(at: absent, offset: 0, count: 1) }
        }
        #expect(throws: StagingIOFault.notFound) { try disk.listDirectory(at: "f", limit: 4) }
        #expect(throws: StagingIOFault.notFound) { try disk.read(at: "l", offset: 0, count: 1) }
        // A link is never resolved as an intermediate component.
        #expect(throws: StagingIOFault.changed) { try disk.status(at: "l/y") }
        #expect(throws: StagingIOFault.changed) { try disk.listDirectory(at: "l", limit: 4) }

        let refused: [(String, StagingRefusal)] = [
            ("l", .destinationRefused), ("f", .destinationRefused), ("missing", .destinationRefused),
            ("l/y", .packageIO(.destinationParentRefused))
        ]
        for (path, refusal) in refused {
            #expect(throws: refusal, "\(path)") { _ = try Self.disk(volume.appendingPathComponent(path)) }
        }
    }

    @Test func renameNeverReplaces() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        let manager = FileManager.default
        try manager.createDirectory(at: volume.appendingPathComponent("a"), withIntermediateDirectories: false)
        try Data([1]).write(to: volume.appendingPathComponent("a/keep"))
        try manager.createDirectory(at: volume.appendingPathComponent("b"), withIntermediateDirectories: false)
        try Data([2]).write(to: volume.appendingPathComponent("c"))
        let disk = try Self.disk(volume)

        #expect(throws: StagingIOFault.exists) { try disk.rename(from: "a", to: "b") }
        #expect(throws: StagingIOFault.exists) { try disk.rename(from: "a", to: "c") }
        #expect(throws: StagingIOFault.exists) { try disk.rename(from: "c", to: "b") }
        #expect(throws: StagingIOFault.notFound) { try disk.rename(from: "missing", to: "z") }
        #expect(try Self.diskNames(volume) == ["a", "b", "c"])
        #expect(try Self.diskNames(volume.appendingPathComponent("a")) == ["keep"])
        #expect(try Self.diskNames(volume.appendingPathComponent("b")).isEmpty)
        #expect(try Data(contentsOf: volume.appendingPathComponent("c")) == Data([2]))

        try disk.rename(from: "a", to: "b/z")
        #expect(try Self.diskNames(volume) == ["b", "c"])
        #expect(try Self.diskNames(volume.appendingPathComponent("b/z")) == ["keep"])
    }

    @Test func sameSizeRewriteDuringReadIsMemberChanged() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        try ProjectPackageWriter.write(Fixture.big("src"), to: volume.appendingPathComponent(Fixture.source))
        let project = volume.appendingPathComponent(Fixture.source).appendingPathComponent("project.json")
        var disk = try Self.disk(volume)
        Self.hook(disk, at: .read, of: Fixture.source + "/project.json") {
            // Same size, same inode: only the status-change time shows the rewrite.
            let handle = FileHandle(forWritingAtPath: project.path)
            #expect(handle != nil)
            try? handle?.write(contentsOf: Data("Q-src".utf8))
            try? handle?.close()
        }
        let policy = try Fixture.policy()
        let result = Self.onDisk { () throws(StagingRefusal) in
            try StagedPackageImport.read(from: Fixture.source, policy: policy, chunkByteCount: 64, in: &disk)
        }
        #expect(Fixture.refusal(result) == .packageIO(.memberChanged))
        #expect(try Data(contentsOf: project) == Data("Q-src".utf8))
    }

    @Test func invalidComponentsDeniedWithoutIO() throws {
        let scratch = try Self.diskScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let volume = Self.diskVolume(scratch)
        try FileManager.default.createDirectory(
            at: volume.appendingPathComponent("x"), withIntermediateDirectories: false
        )
        let disk = try Self.disk(volume)
        var hookCalls = 0
        disk.operationHookForTesting = { _, _ in hookCalls += 1 }
        let invalid = ["a//b", "/a", "a/", ".", "..", "x/./b", "x/../b", "../escape", "a\u{0}b", "x/.."]
        for path in invalid {
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.status(at: path) }
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.listDirectory(at: path, limit: 4) }
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.read(at: path, offset: 0, count: 1) }
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.syncDirectory(at: path) }
        }
        for path in invalid + [""] {
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.makeDirectory(at: path) }
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.createFile(at: path, bytes: Data([1])) }
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.removeTree(at: path) }
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.rename(from: path, to: "y") }
            #expect(throws: StagingIOFault.denied, "\(path)") { try disk.rename(from: "x", to: path) }
        }
        #expect(hookCalls == 0)
        #expect(try Self.diskNames(volume) == ["x"])
        #expect(try Self.diskNames(volume.appendingPathComponent("x")).isEmpty)
        #expect(try Self.diskNames(scratch) == ["vol"])
    }
}
