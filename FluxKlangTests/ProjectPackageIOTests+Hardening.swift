import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectPackageIOTests {
    private typealias Support = PackageIOTestSupport

    @Test func escapingAndAbsolutePathsAreRefusedBeforeAnyWrite() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let escapes: [(directories: [String], file: String?)] = [
            ([], "../escape.bin"),
            ([], scratch.appendingPathComponent("absolute.bin").path),
            (["dir"], "dir/../../escape.bin"),
            ([".."], nil)
        ]
        for escape in escapes {
            var files = Support.files
            if let file = escape.file { files[file] = Data([1]) }
            #expect(throws: ProjectPackageError.invalidPath) {
                let contents = try ProjectPackageContents(
                    manifestBytes: Support.manifestBytes(), directories: Support.directories + escape.directories,
                    files: files, policy: Support.policy()
                )
                try ProjectPackageWriter.write(contents, to: scratch.appendingPathComponent("dest.fluxklang"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        }
    }

    @Test func linkedOrNonDirectoryDestinationParentIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try Support.makePackage(in: Support.scratchChild(scratch, "source"))
        let contents = try Support.read(source)
        let target = try Support.scratchChild(scratch, "target")
        let linkedParent = scratch.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: target)
        let fileParent = scratch.appendingPathComponent("plain.bin")
        try Data([1]).write(to: fileParent)
        for parent in [linkedParent, fileParent] {
            #expect(throws: ProjectPackageIOError.destinationParentRefused) {
                try ProjectPackageWriter.write(contents, to: parent.appendingPathComponent("dest.fluxklang"))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func writerIOFailureLeavesPartialOutputOnlyInsideTheNewDestination() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Admitted by the 256-byte P1 path limit, but longer than the 255-byte file-name limit.
        let overlong = String(repeating: "z", count: 256)
        var files = Support.files
        files[overlong] = Data([1])
        let contents = try ProjectPackageContents(
            manifestBytes: Support.manifestBytes(), directories: Support.directories, files: files,
            policy: Support.policy()
        )
        let destination = scratch.appendingPathComponent("dest.fluxklang")
        #expect(throws: ProjectPackageIOError.system(code: ENAMETOOLONG)) {
            try ProjectPackageWriter.write(contents, to: destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["dest.fluxklang"])
        let written = try Set(FileManager.default.contentsOfDirectory(atPath: destination.path))
        #expect(written == Set(["manifest.json", "unknown.bin"] + Support.directories.filter { !$0.contains("/") }))
        #expect(try Data(contentsOf: destination.appendingPathComponent("unknown.bin")) == Support.files["unknown.bin"])
    }

    @Test func hardLinkedMembersAreRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cases: [(String, String)] = [("notes/readme.txt", "outside"), ("state/draft.bin", "inside")]
        for (member, label) in cases {
            let root = try Support.makePackage(in: Support.scratchChild(scratch, label))
            let alias = label == "outside"
                ? scratch.appendingPathComponent("alias.bin")
                : root.appendingPathComponent("notes/alias.bin")
            #expect(link(root.appendingPathComponent(member).path, alias.path) == 0)
            #expect(throws: ProjectPackageIOError.hardLinkedMember) { try Support.read(root) }
        }
    }

    @Test func hardLinkAddedBetweenAdmissionAndOpenIsRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for member in ["manifest.json", "unknown.bin"] {
            let root = try Support.makePackage(in: Support.scratchChild(scratch, member))
            let target = root.appendingPathComponent(member).path
            let alias = scratch.appendingPathComponent("\(member).alias").path
            var reader = try ProjectPackageReader(policy: Support.policy())
            reader.openHookForTesting = { path in
                guard path == member else { return }
                #expect(link(target, alias) == 0)
            }
            #expect(throws: ProjectPackageIOError.hardLinkedMember) { try reader.read(from: root) }
        }
    }

    @Test func memberChangedWhileOpenIsRefusedAtEOF() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let edits: [(String, @Sendable (FileHandle) throws -> Void)] = [
            ("overwrite", { try $0.write(contentsOf: Data([9, 9, 9, 9])) }),
            ("append", { _ = try $0.seekToEnd(); try $0.write(contentsOf: Data([5])) })
        ]
        for (label, edit) in edits {
            let root = try Support.makePackage(in: Support.scratchChild(scratch, label))
            let target = root.appendingPathComponent("unknown.bin")
            var reader = try ProjectPackageReader(policy: Support.policy(), chunkByteCount: 1)
            reader.chunkHookForTesting = { path, retained in
                guard path == "unknown.bin", retained == 1, let handle = try? FileHandle(forWritingTo: target) else {
                    return
                }
                try? edit(handle)
                try? handle.close()
            }
            #expect(throws: ProjectPackageIOError.memberChanged) { try reader.read(from: root) }
        }
        var observed = try ProjectPackageReader(policy: Support.policy(), chunkByteCount: 1)
        observed.chunkHookForTesting = { _, _ in }
        let unchanged = try Support.makePackage(in: Support.scratchChild(scratch, "unchanged"))
        #expect(try observed.read(from: unchanged).files.count == Support.files.count)
    }

    @Test func zeroRemainingAllowanceStillProbesForEOF() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var emptyDeclared = Support.manifest()
        emptyDeclared.opaqueState = [ProjectPackageMember(path: "state/draft.bin", byteCount: 0)]
        let manifest = try Support.manifestBytes(emptyDeclared)
        var files = Support.files
        files["state/draft.bin"] = Data()
        let exact = manifest.count + files.values.reduce(0) { $0 + $1.count }
        let policy = try Support.policy(entryBytes: exact, totalBytes: exact, manifestBytes: manifest.count)
        for chunk in [1, 4096] {
            files["zz-last.bin"] = Data()
            let fits = try Support.makePackage(
                in: Support.scratchChild(scratch, "fits\(chunk)"), manifest: manifest, files: files
            )
            #expect(try Support.read(fits, policy: policy, chunk: chunk).files.count == files.count)
            files["zz-last.bin"] = Data([1])
            let over = try Support.makePackage(
                in: Support.scratchChild(scratch, "over\(chunk)"), manifest: manifest, files: files
            )
            #expect(throws: ProjectPackageError.totalBytesExceeded) {
                try Support.read(over, policy: policy, chunk: chunk)
            }
        }
    }
}
