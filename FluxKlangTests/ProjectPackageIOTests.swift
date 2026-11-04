import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum PackageIOTestSupport {
    /// SHA-256 of the ASCII bytes "abc" (FIPS 180-2 test vector).
    static let mediaDigest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let listed: [String: Data] = [
        "documents/project.json": Data(#"{"contract":"fluxklang.project","version":99}"#.utf8),
        "graphs/main.json": Data(#"{"future":"graph"}"#.utf8),
        "media/click.wav": Data("abc".utf8),
        "references/a.bookmark": Data([0xB0, 0x0C]),
        "state/draft.bin": Data([0xFF, 0x00, 0xFE])
    ]
    static let unlisted: [String: Data] = [
        "notes/readme.txt": Data("keep".utf8),
        "unknown.bin": Data([1, 2, 3, 4])
    ]
    static let directories = ["documents", "empty", "empty/nested", "graphs", "media", "notes", "references", "state"]
    static var files: [String: Data] { listed.merging(unlisted) { first, _ in first } }

    static func policy(
        entries: Int = 32, entryBytes: Int = 4096, totalBytes: Int = 16_384, manifestBytes: Int = 2048
    ) throws -> ProjectPackageManifestPolicy {
        try ProjectPackageManifestPolicy(
            packageLimits: ProjectPackageLimits(
                maxEntries: entries, maxDepth: 8, maxPathUTF8Bytes: 256,
                maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            ),
            maxManifestBytes: manifestBytes
        )
    }

    static func manifest() -> ProjectPackageManifest {
        func member(_ path: String) -> ProjectPackageMember {
            ProjectPackageMember(path: path, byteCount: listed[path]?.count)
        }
        return ProjectPackageManifest(
            project: ProjectPackageProjectReference(
                id: ProjectID(validated: "prj.set"), revision: .initial, member: member("documents/project.json")
            ),
            graphs: [ProjectPackageGraphReference(
                graph: GraphID(validated: "gph.main"), revision: .initial, member: member("graphs/main.json")
            )],
            resources: [ProjectPackageResource(
                contentDigest: mediaDigest, media: member("media/click.wav"),
                bookmarks: [member("references/a.bookmark")]
            )],
            opaqueState: [member("state/draft.bin")]
        )
    }

    static func manifestBytes(_ manifest: ProjectPackageManifest = manifest()) throws -> Data {
        try manifest.encoded(policy: policy())
    }

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectPackageIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Writes a fixture package with Foundation, independently of the writer under test.
    static func makePackage(
        in scratch: URL,
        manifest: Data? = nil,
        files: [String: Data] = files,
        directories: [String] = directories
    ) throws -> URL {
        let root = scratch.appendingPathComponent("fixture.fluxklang", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        try (manifest ?? manifestBytes()).write(to: root.appendingPathComponent("manifest.json"))
        for (path, bytes) in files {
            try bytes.write(to: root.appendingPathComponent(path))
        }
        return root
    }

    static func read(
        _ root: URL, policy: ProjectPackageManifestPolicy? = nil, chunk: Int = 2
    ) throws -> ProjectPackageContents {
        try ProjectPackageReader(policy: policy ?? self.policy(), chunkByteCount: chunk).read(from: root)
    }
}

struct ProjectPackageIOTests {
    private typealias Support = PackageIOTestSupport

    @Test func readRetainsOriginalBytesOfListedUnsupportedAndUnlistedMembers() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manifestBytes = try Support.manifestBytes()
        let contents = try Support.read(Support.makePackage(in: scratch, manifest: manifestBytes))

        #expect(contents.manifestBytes == manifestBytes)
        #expect(contents.manifest == Support.manifest())
        #expect(contents.directories == Support.directories)
        #expect(Dictionary(uniqueKeysWithValues: contents.files.map { ($0.path, $0.bytes) }) == Support.files)
        let roles = Dictionary(uniqueKeysWithValues: contents.files.map { ($0.path, $0.role) })
        #expect(roles == [
            "documents/project.json": .project,
            "graphs/main.json": .graph(GraphID(validated: "gph.main")),
            "media/click.wav": .media(contentDigest: Support.mediaDigest),
            "references/a.bookmark": .bookmark(contentDigest: Support.mediaDigest),
            "state/draft.bin": .opaqueState,
            "notes/readme.txt": .unlisted,
            "unknown.bin": .unlisted
        ])
    }

    @Test func writerRoundTripsByteIdenticalPackageIntoNewDestinationOnly() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = try Support.read(Support.makePackage(in: scratch))
        let copy = scratch.appendingPathComponent("copy.fluxklang", isDirectory: true)
        try ProjectPackageWriter.write(original, to: copy)

        #expect(try Support.read(copy, chunk: 4096) == original)
        #expect(try Data(contentsOf: copy.appendingPathComponent("manifest.json")) == original.manifestBytes)
        for (path, bytes) in Support.files {
            #expect(try Data(contentsOf: copy.appendingPathComponent(path)) == bytes)
        }
        #expect(throws: ProjectPackageIOError.destinationExists) { try ProjectPackageWriter.write(original, to: copy) }
        let link = scratch.appendingPathComponent("link.fluxklang")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch)
        #expect(throws: ProjectPackageIOError.destinationExists) { try ProjectPackageWriter.write(original, to: link) }
    }

    @Test func chunkPartitionDoesNotChangeTheRetainedValue() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try Support.makePackage(in: scratch)
        let expected = try Support.read(root, chunk: 1)
        for chunk in [2, 3, 7, 1 << 20] {
            #expect(try Support.read(root, chunk: chunk) == expected)
        }
        #expect(throws: ProjectPackageError.invalidLimits) {
            try ProjectPackageReader(policy: Support.policy(), chunkByteCount: 0)
        }
    }

    @Test func declaredLengthsAreCheckedAgainstActualBytesThroughEOF() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var truncated = Support.files
        truncated["state/draft.bin"] = Data([0xFF, 0x00])
        #expect(throws: ProjectPackageError.declaredByteCountMismatch) {
            try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "truncated"), files: truncated))
        }
        var extended = Support.files
        extended["state/draft.bin"] = Data([0xFF, 0x00, 0xFE, 0x01])
        for chunk in [1, 3, 64] {
            #expect(throws: ProjectPackageError.declaredBytesExceeded) {
                try Support.read(
                    Support.makePackage(in: Support.scratchChild(scratch, "extended\(chunk)"), files: extended),
                    chunk: chunk
                )
            }
        }
        var emptyDeclared = Support.manifest()
        emptyDeclared.opaqueState = [ProjectPackageMember(path: "state/draft.bin", byteCount: 0)]
        #expect(throws: ProjectPackageError.declaredBytesExceeded) {
            try Support.read(Support.makePackage(
                in: Support.scratchChild(scratch, "zero"), manifest: Support.manifestBytes(emptyDeclared)
            ))
        }
    }

    @Test func undeclaredAndManifestBytesStopAtTheirLimits() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var files = Support.files
        files["unknown.bin"] = Data(repeating: 7, count: 4096)
        let root = try Support.makePackage(in: scratch, files: files)
        let total = try Support.manifestBytes().count + files.values.reduce(0) { $0 + $1.count }

        #expect(try Support.read(root, policy: Support.policy(entryBytes: 4096, totalBytes: total)).files.count == 7)
        #expect(throws: ProjectPackageError.entryBytesExceeded) {
            try Support.read(root, policy: Support.policy(entryBytes: 4095, totalBytes: total))
        }
        #expect(throws: ProjectPackageError.totalBytesExceeded) {
            try Support.read(root, policy: Support.policy(entryBytes: 4096, totalBytes: total - 1))
        }
        let manifestCount = try Support.manifestBytes().count
        #expect(throws: ProjectPackageManifestError.manifestBytesExceeded) {
            try Support.read(root, policy: Support.policy(manifestBytes: manifestCount - 1), chunk: 4096)
        }
    }

    @Test func membershipAndEmbeddedDigestAreVerified() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var corrupted = Support.files
        corrupted["media/click.wav"] = Data("abd".utf8)
        #expect(throws: ProjectPackageIOError.digestMismatch) {
            try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "digest"), files: corrupted))
        }
        var missing = Support.files
        missing["graphs/main.json"] = nil
        #expect(throws: ProjectPackageIOError.missingMember) {
            try Support.read(Support.makePackage(in: Support.scratchChild(scratch, "missing"), files: missing))
        }
        var retyped = Support.files
        retyped["state/draft.bin"] = nil
        #expect(throws: ProjectPackageIOError.missingMember) {
            try Support.read(Support.makePackage(
                in: Support.scratchChild(scratch, "retyped"), files: retyped,
                directories: Support.directories + ["state/draft.bin"]
            ))
        }
        let noManifest = try Support.makePackage(in: Support.scratchChild(scratch, "manifest"))
        try FileManager.default.removeItem(at: noManifest.appendingPathComponent("manifest.json"))
        #expect(throws: ProjectPackageIOError.missingMember) { try Support.read(noManifest) }
    }

    @Test func linksAndSpecialFilesAreRefusedWithoutBeingFollowed() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outside = scratch.appendingPathComponent("outside.bin")
        try Data("secret".utf8).write(to: outside)
        let cases: [(String, (URL) throws -> Void)] = [
            ("fileLink", { try FileManager.default.createSymbolicLink(
                at: $0.appendingPathComponent("notes/escape"), withDestinationURL: outside
            ) }),
            ("directoryLink", { try FileManager.default.createSymbolicLink(
                at: $0.appendingPathComponent("escape"), withDestinationURL: scratch
            ) }),
            ("listedInnerLink", {
                let member = $0.appendingPathComponent("state/draft.bin")
                try FileManager.default.moveItem(at: member, to: $0.appendingPathComponent("state/real.bin"))
                try FileManager.default.createSymbolicLink(atPath: member.path, withDestinationPath: "real.bin")
            }),
            ("fifo", { #expect(mkfifo($0.appendingPathComponent("notes/pipe").path, 0o600) == 0) })
        ]
        for (label, mutate) in cases {
            let root = try Support.makePackage(in: Support.scratchChild(scratch, label))
            try mutate(root)
            #expect(throws: ProjectPackageError.unsupportedKind) { try Support.read(root) }
        }
        let linkedRoot = scratch.appendingPathComponent("linked.fluxklang")
        let target = try Support.makePackage(in: Support.scratchChild(scratch, "target"))
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        #expect(throws: ProjectPackageIOError.self) { try Support.read(linkedRoot) }
    }

    @Test func unsafeOnDiskNamesAndEntryCountsAreRefused() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let names: [(String, ProjectPackageError)] = [
            ("e\u{301}.txt", .nonNFCPath), ("a:b", .invalidPath), ("a\\b", .invalidPath), ("trailing ", .invalidPath)
        ]
        for (index, (name, error)) in names.enumerated() {
            var files = Support.files
            files["notes/" + name] = Data([0])
            let root = try Support.makePackage(in: Support.scratchChild(scratch, "name\(index)"), files: files)
            #expect(throws: error) { try Support.read(root) }
        }
        let root = try Support.makePackage(in: Support.scratchChild(scratch, "count"))
        let entries = 1 + Support.directories.count + Support.files.count
        #expect(try Support.read(root, policy: Support.policy(entries: entries)).files.count == 7)
        #expect(throws: ProjectPackageError.entryLimitExceeded) {
            try Support.read(root, policy: Support.policy(entries: entries - 1))
        }
    }

    @Test func inMemoryContentsAreVerifiedBeforeAnyWrite() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manifest = try Support.manifestBytes()
        let policy = try Support.policy()
        func build(files: [String: Data] = Support.files, directories: [String] = Support.directories) throws {
            _ = try ProjectPackageContents(
                manifestBytes: manifest, directories: directories, files: files, policy: policy
            )
        }
        var corrupted = Support.files
        corrupted["media/click.wav"] = Data("abd".utf8)
        #expect(throws: ProjectPackageIOError.digestMismatch) { try build(files: corrupted) }
        var missing = Support.files
        missing["references/a.bookmark"] = nil
        #expect(throws: ProjectPackageIOError.missingMember) { try build(files: missing) }
        #expect(throws: ProjectPackageError.missingParent) { try build(directories: ["empty/nested"]) }
        var shadowing = Support.files
        shadowing["manifest.json"] = Data()
        #expect(throws: ProjectPackageError.duplicatePath) { try build(files: shadowing) }

        let contents = try ProjectPackageContents(
            manifestBytes: manifest, directories: Support.directories, files: Support.files, policy: policy
        )
        let destination = scratch.appendingPathComponent("memory.fluxklang")
        try ProjectPackageWriter.write(contents, to: destination)
        #expect(try Support.read(destination) == contents)
    }
}

extension PackageIOTestSupport {
    static func scratchChild(_ scratch: URL, _ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
