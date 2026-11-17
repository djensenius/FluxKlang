import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectPackageIOTests {
    /// One on-disk variant of the inspectable package and the refusal it must produce.
    private struct InspectionVariant {
        let name: String
        let manifest: Data
        let files: [String: Data]
        let expected: ProjectPackageInspectionRefusal

        init(
            _ name: String, manifest: Data, files: [String: Data] = PackageIOTestSupport.inspectableFiles,
            _ expected: ProjectPackageInspectionRefusal
        ) {
            self.name = name
            self.manifest = manifest
            self.files = files
            self.expected = expected
        }
    }

    private typealias Support = PackageIOTestSupport
    private typealias Refusal = ProjectPackageInspectionRefusal

    private static func refusal(
        _ root: URL, policy: ProjectPackageManifestPolicy? = nil, hook: (@Sendable (String, Int) -> Void)? = nil
    ) -> Refusal? {
        var loader = ProjectPackageInspectionLoader(policy: policy)
        loader.chunkHookForTesting = hook
        do {
            _ = try loader.inspect(at: root)
            return nil
        } catch {
            return error
        }
    }

    private static func limits(
        entries: Int, depth: Int = 8, pathBytes: Int = 256, entryBytes: Int = 4096, totalBytes: Int,
        manifestBytes: Int = 2048
    ) throws -> ProjectPackageManifestPolicy {
        try ProjectPackageManifestPolicy(
            packageLimits: ProjectPackageLimits(
                maxEntries: entries, maxDepth: depth, maxPathUTF8Bytes: pathBytes,
                maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            ),
            maxManifestBytes: manifestBytes
        )
    }

    /// Replaces text that must be present in encoded JSON.
    private static func replacing(_ data: Data, _ target: String, with replacement: String) throws -> Data {
        let text = try #require(String(data: data, encoding: .utf8))
        try #require(text.contains(target))
        return Data(text.replacingOccurrences(of: target, with: replacement).utf8)
    }

    @Test func eachInspectionAdmissionLimitRefusesWithItsOwnCase() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var files = Support.files
        files["unknown.bin"] = Data(repeating: 7, count: 4096)
        let root = try Support.makePackage(in: scratch, files: files)
        let manifestCount = try Support.manifestBytes().count
        let total = manifestCount + files.values.reduce(0) { $0 + $1.count }
        let entries = 1 + Support.directories.count + files.count

        // Within every limit the read completes and only decoding refuses: the fixture project is version 99.
        let admitted = try Self.limits(entries: entries, totalBytes: total)
        #expect(Self.refusal(root, policy: admitted) == .unsupportedDocument)
        let refused: [(ProjectPackageManifestPolicy, Refusal)] = try [
            (Self.limits(entries: entries - 1, totalBytes: total), .tooManyEntries),
            (Self.limits(entries: entries, depth: 1, totalBytes: total), .tooDeep),
            (Self.limits(entries: entries, pathBytes: 13, totalBytes: total), .pathTooLong),
            (Self.limits(entries: entries, entryBytes: 4095, totalBytes: total), .memberTooLarge),
            (Self.limits(entries: entries, totalBytes: total - 1), .packageTooLarge),
            (Self.limits(entries: entries, totalBytes: total, manifestBytes: manifestCount - 1), .manifestTooLarge)
        ]
        for (policy, expected) in refused {
            #expect(Self.refusal(root, policy: policy) == expected)
        }
    }

    @Test func defaultInspectionPolicyAdmitsSixteenLevelsAndRefusesSeventeen() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cases: [(depth: Int, expected: Refusal)] = [(16, .unsupportedDocument), (17, .tooDeep)]
        for (depth, expected) in cases {
            let chain = (1..<depth).map { Array(repeating: "d", count: $0).joined(separator: "/") }
            var files = Support.files
            files[(chain.last ?? "") + "/f.bin"] = Data([1])
            let root = try Support.makePackage(
                in: Support.scratchChild(scratch, "depth\(depth)"), files: files,
                directories: Support.directories + chain
            )
            #expect(Self.refusal(root) == expected)
        }
    }

    @Test func inspectionLocationFailuresMapToBoundedCases() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let package = try Support.makeInspectablePackage(in: Support.scratchChild(scratch, "package"))
        #expect(Self.refusal(package) == nil)
        #expect(Self.refusal(scratch.appendingPathComponent("absent.fluxklang")) == .notFound)
        let plain = scratch.appendingPathComponent("plain.fluxklang")
        try Data([1]).write(to: plain)
        #expect(Self.refusal(plain) == .notAPackage)
        let link = scratch.appendingPathComponent("link.fluxklang")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        // The root is opened `O_DIRECTORY|O_NOFOLLOW`; Darwin reports a linked root as ENOTDIR.
        #expect(Self.refusal(link) == .notAPackage)
        let bare = try Support.scratchChild(scratch, "bare")
        #expect(Self.refusal(bare) == .missingMember)
    }

    @Test func inspectionMemberFailuresMapToBoundedCases() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        func makeRoot(_ name: String, edit: (inout [String: Data]) -> Void = { _ in }) throws -> URL {
            var files = Support.inspectableFiles
            edit(&files)
            return try Support.makeInspectablePackage(in: Support.scratchChild(scratch, name), files: files)
        }
        let edited: [(URL, Refusal)] = try [
            (makeRoot("digest") { $0["media/click.wav"] = Data("abd".utf8) }, .digestMismatch),
            (makeRoot("short") { $0["state/draft.bin"] = Data([0xFF]) }, .declaredLengthMismatch),
            (makeRoot("missing") { $0["graphs/main.json"] = nil }, .missingMember),
            (makeRoot("nfc") { $0["notes/e\u{301}.txt"] = Data([0]) }, .invalidMemberName)
        ]
        for (root, expected) in edited {
            #expect(Self.refusal(root) == expected)
        }

        let linked = try makeRoot("linked")
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("notes/escape"), withDestinationURL: scratch
        )
        #expect(Self.refusal(linked) == .unsupportedEntry)
        let hardLinked = try makeRoot("hardLinked")
        let member = hardLinked.appendingPathComponent("notes/readme.txt")
        #expect(link(member.path, scratch.appendingPathComponent("alias.txt").path) == 0)
        #expect(Self.refusal(hardLinked) == .unsupportedEntry)
        let unreadable = try makeRoot("unreadable")
        let unreadablePath = unreadable.appendingPathComponent("notes/readme.txt").path
        #expect(chmod(unreadablePath, 0) == 0)
        defer { chmod(unreadablePath, 0o644) }
        #expect(Self.refusal(unreadable) == .accessDenied)

        let changed = try makeRoot("changed")
        let target = changed.appendingPathComponent("unknown.bin")
        let refusal = Self.refusal(changed) { path, retained in
            guard path == "unknown.bin", retained == 4, let handle = try? FileHandle(forWritingTo: target) else {
                return
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data([5]))
            try? handle.close()
        }
        #expect(refusal == .changedWhileReading)
    }

    @Test func inspectionManifestAndDocumentFailuresMapToBoundedCases() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manifest = try Support.manifestBytes(Support.inspectableManifest())
        let contract = #""contract":"fluxklang.project-package""#
        let projectPath = #","path":"documents/project.json""#
        let projectMember = #""byteCount":\#(Support.inspectableProject.count)"# + projectPath
        // One byte over the 4 MiB document bound, which the manifest refuses before any member is read.
        let oversizedMember = #""byteCount":4194305"# + projectPath
        var mismatched = try Support.inspectableManifest()
        mismatched.graphs[0].revision = try ContractRevision(6)
        let variants: [InspectionVariant] = try [
            InspectionVariant("malformed", manifest: Data("{not json".utf8), .unreadableManifest),
            InspectionVariant(
                "contract", manifest: Self.replacing(manifest, contract, with: #""contract":"other""#),
                .unreadableManifest
            ),
            InspectionVariant(
                "version", manifest: Self.replacing(manifest, #""version":1}"#, with: #""version":2}"#),
                .unsupportedManifest
            ),
            InspectionVariant(
                "features",
                manifest: Self.replacing(manifest, contract, with: contract + #","requiredFeatures":["x.v9"]"#),
                .unsupportedManifest
            ),
            InspectionVariant(
                "bounds", manifest: Self.replacing(manifest, projectMember, with: oversizedMember), .documentTooLarge
            ),
            InspectionVariant("mismatch", manifest: Support.manifestBytes(mismatched), .inconsistentManifest),
            Self.withDocument("graphs/main.json", Data(#"{"contract":"fluxklang.graph","version":1}"#.utf8),
                              .undecodableDocument),
            Self.withDocument("documents/project.json", Data(#"{"name":"Old set"}"#.utf8), .legacyDocument),
            Self.withDocument("graphs/main.json", Data(#"{"contract":"fluxklang.graph","version":2}"#.utf8),
                              .unsupportedDocument)
        ]
        for variant in variants {
            let root = try Support.makePackage(
                in: Support.scratchChild(scratch, variant.name), manifest: variant.manifest, files: variant.files
            )
            #expect(Self.refusal(root) == variant.expected, "\(variant.name)")
        }
    }

    /// The inspectable package with one document replaced and its declared length updated.
    private static func withDocument(_ path: String, _ bytes: Data, _ expected: Refusal) throws -> InspectionVariant {
        var manifest = try Support.inspectableManifest()
        if path == manifest.project.member.path {
            manifest.project.member.byteCount = bytes.count
        } else {
            manifest.graphs[0].member.byteCount = bytes.count
        }
        var files = Support.inspectableFiles
        files[path] = bytes
        return try InspectionVariant("\(expected)", manifest: Support.manifestBytes(manifest), files: files, expected)
    }

    @Test func inspectionRefusalsCarryNoPathIdentityOrDecoderText() throws {
        let secret = "secret-path"
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manifest = try Self.replacing(
            Support.manifestBytes(), #""contract":"fluxklang.project-package""#, with: #""contract":"\#(secret)""#
        )
        let root = try Support.makePackage(in: Support.scratchChild(scratch, secret), manifest: manifest)
        // The reader's own error names the untrusted contract; the refusal has nowhere to keep it.
        #expect(throws: ContractVersionError.wrongContract(expected: "fluxklang.project-package", found: secret)) {
            try Support.read(root)
        }
        let refusals = [Self.refusal(root), Self.refusal(scratch.appendingPathComponent(secret + "/absent"))]
        #expect(refusals == [.unreadableManifest, .notFound])
        for refusal in Refusal.allCases {
            #expect(Mirror(reflecting: refusal).children.isEmpty)
            for text in [String(describing: refusal), String(reflecting: refusal)] {
                #expect(!text.contains(secret))
                #expect(!text.contains("/"))
            }
        }
    }

    @Test func wrappedAndNonReaderErrorsMapWithoutTheirPayloads() {
        let graph = GraphID(validated: "gph.secret")
        let cases: [(any Error, Refusal)] = [
            (ProjectPackageDocumentError.undecodableGraph(graph), .undecodableDocument),
            (ProjectPackageDocumentError.unsupportedGraph(graph), .unsupportedDocument),
            (ProjectPackageDocumentError.legacyGraph(graph), .legacyDocument),
            (ProjectPackageDocumentError.graphBounds(graph), .documentTooLarge),
            (ProjectPackageDocumentError.package(.invalidLimits), .invalidPolicy),
            (ProjectPackageDocumentError.manifest(.graphMismatch), .inconsistentManifest),
            (ProjectPackageDocumentError.packageIO(.system(code: EPERM)), .accessDenied),
            (ProjectPackageIOError.system(code: ELOOP), .unsupportedEntry),
            (ProjectPackageIOError.crossedMountPoint, .unsupportedEntry),
            (ProjectPackageIOError.system(code: EIO), .readFailed),
            (ProjectPackageIOError.destinationChanged, .readFailed),
            (ProjectGraphVersionError.unsupportedRequiredFeatures(["secret"]), .unsupportedManifest),
            (CancellationError(), .readFailed)
        ]
        for (error, expected) in cases {
            #expect(Refusal(error) == expected)
        }
    }
}
