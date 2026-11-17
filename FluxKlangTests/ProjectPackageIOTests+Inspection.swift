import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A decodable variant of the on-disk fixture: hand-written, non-canonical documents at pinned revisions
/// with unknown fields and extensions, beside the fixture's media, bookmark, opaque, unlisted and empty
/// directory members.
extension PackageIOTestSupport {
    static let inspectableProject = Data(#"""
    {"contract":"fluxklang.project","version":1,"id":"prj.set","revision":3,"name":"Set",
     "graphs":[{"graph":"gph.main","revision":5,"futureReference":[1,2]}],"roles":[],
     "extensions":{"vendor":{"kept":true}},"futureProject":{"nested":true}}
    """#.utf8)
    static let inspectableGraph = Data(#"""
    {"contract":"fluxklang.graph","version":1,"id":"gph.main","revision":5,"nodes":[],"edges":[],
     "requiresReview":true,"extensions":{"vendor":"graph"},"futureGraph":"keep"}
    """#.utf8)

    static var inspectableFiles: [String: Data] {
        var files = Self.files
        files["documents/project.json"] = inspectableProject
        files["graphs/main.json"] = inspectableGraph
        return files
    }

    static func inspectableManifest() throws -> ProjectPackageManifest {
        var manifest = Self.manifest()
        manifest.project.revision = try ContractRevision(3)
        manifest.project.member.byteCount = inspectableProject.count
        manifest.graphs[0].revision = try ContractRevision(5)
        manifest.graphs[0].member.byteCount = inspectableGraph.count
        manifest.extensions = ["vendor": .string("manifest")]
        manifest.unknownFields = ["futureManifest": .int(1)]
        manifest.resources[0].unknownFields = ["futureResource": .bool(true)]
        return manifest
    }

    static func makeInspectablePackage(
        in scratch: URL, manifest: ProjectPackageManifest? = nil, files: [String: Data] = inspectableFiles
    ) throws -> URL {
        try makePackage(in: scratch, manifest: manifestBytes(manifest ?? inspectableManifest()), files: files)
    }

    /// Every file's bytes and every directory under `root`, read with Foundation.
    static func disk(_ root: URL) throws -> (files: [String: Data], directories: Set<String>) {
        var files: [String: Data] = [:]
        var directories = Set<String>()
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            var isDirectory: ObjCBool = false
            let url = root.appendingPathComponent(path)
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                directories.insert(path)
            } else {
                files[path] = try Data(contentsOf: url)
            }
        }
        return (files, directories)
    }
}

/// Chunk-hook observations: the bytes retained so far per member, and whether each chunk ran on main.
private final class InspectionChunkLog: Sendable {
    let retained = Mutex<[String: Int]>([:])
    let onMainThread = Mutex<[Bool]>([])
}

extension ProjectPackageIOTests {
    private typealias Support = PackageIOTestSupport
    private typealias Loader = ProjectPackageInspectionLoader

    @Test func inspectionAdmissionPolicyIsTheReviewedOne() throws {
        let policy = try Loader.admissionPolicy()
        #expect(policy.packageLimits.maxEntries == 4_096)
        #expect(policy.packageLimits.maxDepth == 16)
        #expect(policy.packageLimits.maxPathUTF8Bytes == 1_024)
        #expect(policy.packageLimits.maxEntryBytes == 8_388_608)
        #expect(policy.packageLimits.maxTotalBytes == 33_554_432)
        #expect(policy.maxManifestBytes == 1_048_576)
        #expect(Loader.chunkByteCount == 65_536)
        #expect(Loader().policy == nil)
    }

    @Test func inspectionKeepsEveryOriginalByteAndUnknownValue() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try Support.makeInspectablePackage(in: scratch)
        let disk = try Support.disk(root)
        let documents = try Loader().inspect(at: root).documents
        let contents = documents.contents

        var retained = Dictionary(uniqueKeysWithValues: contents.files.map { ($0.path, $0.bytes) })
        retained["manifest.json"] = contents.manifestBytes
        #expect(retained == disk.files)
        #expect(Set(contents.directories) == disk.directories)
        #expect(contents.directories.contains("empty/nested"))
        #expect(contents.files.first(where: { $0.path == "references/a.bookmark" })
            == ProjectPackageFile(
                path: "references/a.bookmark", role: .bookmark(contentDigest: Support.mediaDigest),
                bytes: Data([0xB0, 0x0C])
            ))
        #expect(contents.files.filter { $0.role == .unlisted }.map(\.path) == ["notes/readme.txt", "unknown.bin"])

        #expect(contents.manifest.unknownFields == ["futureManifest": .int(1)])
        #expect(contents.manifest.extensions == ["vendor": .string("manifest")])
        #expect(contents.manifest.resources.first?.unknownFields == ["futureResource": .bool(true)])
        #expect(documents.project.unknownFields == ["futureProject": .object(["nested": .bool(true)])])
        #expect(documents.project.extensions == ["vendor": .object(["kept": .bool(true)])])
        #expect(documents.project.graphs.first?.unknownFields == ["futureReference": .array([.int(1), .int(2)])])
        #expect(documents.graphs.first?.unknownFields == ["futureGraph": .string("keep")])
        #expect(documents.graphs.first?.extensions == ["vendor": .string("graph")])
    }

    @Test func inspectionPreservesReviewAndPinnedRevisionsAndLeavesThePackageUntouched() throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try Support.makeInspectablePackage(in: scratch)
        let before = try Support.disk(root)
        let inspection = try Loader().inspect(at: root)
        let documents = inspection.documents
        let graphID = GraphID(validated: "gph.main")
        let projectRevision = try ContractRevision(3)
        let graphRevision = try ContractRevision(5)

        #expect(documents.project.revision == projectRevision)
        #expect(documents.contents.manifest.project.revision == projectRevision)
        #expect(documents.project.graphs.map(\.revision) == [graphRevision])
        #expect(documents.contents.manifest.graphs.map(\.revision) == [graphRevision])
        #expect(documents.graphs.map(\.revision) == [graphRevision])
        #expect(documents.graphs.map(\.requiresReview) == [true])

        let diagnostics = inspection.diagnostics
        #expect(diagnostics.validationErrors == [.graph(graphID, .reviewRequired)])
        #expect(diagnostics.droppedValidationErrorCount == 0)
        #expect(diagnostics.reviewRequiredGraphs == [graphID])
        let counts = diagnostics.memberCounts
        let counted = [counts.project, counts.graphs, counts.media, counts.bookmarks, counts.opaqueState]
        #expect(counted == [1, 1, 1, 1, 1])
        #expect(counts.unlisted == 2)
        #expect(diagnostics.directoryCount == Support.directories.count)
        #expect(diagnostics.totalByteCount == before.files.values.reduce(0) { $0 + $1.count })

        let after = try Support.disk(root)
        #expect(after.files == before.files)
        #expect(after.directories == before.directories)
    }

    @Test func diagnosticsRetainTheFirstErrorsAndCountTheRest() throws {
        typealias Documents = DocumentsTestSupport
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var project = Documents.project()
        // An audio role without a channel count is invalid, so each role adds one error.
        project.roles = try (0..<300).map { index in
            try ProjectRole(id: RoleID("role.r\(index)"), label: "R", direction: .output, signal: .audio)
        }
        let contents = try ProjectPackageContents.make(
            project: (Documents.projectPath, project), graphs: [(Documents.graphPath, Documents.graph())],
            extraFiles: [], policy: Loader.admissionPolicy()
        )
        let root = scratch.appendingPathComponent("roles.fluxklang")
        try ProjectPackageWriter.write(contents, to: root)

        let diagnostics = try Loader().inspect(at: root).diagnostics
        let expected = project.validationErrors(graphs: [Documents.graph()])
        try #require(expected.count == 301)
        #expect(ProjectPackageInspection.maxRetainedValidationErrors == 256)
        #expect(diagnostics.validationErrors == Array(expected.prefix(256)))
        #expect(diagnostics.droppedValidationErrorCount == 45)
        // The review error is past the cap, but the review list still names the graph.
        #expect(!diagnostics.validationErrors.contains(.graph(Documents.graphID, .reviewRequired)))
        #expect(diagnostics.reviewRequiredGraphs == [Documents.graphID])
    }

    @Test func cancellationLetsTheStartedReadFinishThenRefuses() async throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try Support.makeInspectablePackage(in: scratch)
        let log = InspectionChunkLog()
        var loader = Loader()
        loader.chunkHookForTesting = { path, retained in
            withUnsafeCurrentTask { $0?.cancel() }
            log.retained.withLock { $0[path] = retained }
        }
        let load = Task { [loader] in try await loader.load(at: root) }
        await #expect(throws: ProjectPackageInspectionRefusal.cancelled) { try await load.value }

        // The first chunk cancelled the task; every later member was still read in full.
        var expected = Support.inspectableFiles.mapValues(\.count)
        expected["manifest.json"] = try Support.manifestBytes(Support.inspectableManifest()).count
        #expect(log.retained.withLock { $0 } == expected)
        let uncancelled = try await Loader().load(at: root)
        #expect(uncancelled.documents.graphs.map(\.id) == [GraphID(validated: "gph.main")])
    }

    @MainActor @Test func loadReadsOffTheMainActor() async throws {
        let scratch = try Support.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try Support.makeInspectablePackage(in: scratch)
        let log = InspectionChunkLog()
        var loader = Loader()
        loader.chunkHookForTesting = { _, _ in
            let onMain = Thread.isMainThread
            log.onMainThread.withLock { $0.append(onMain) }
        }
        _ = try await loader.load(at: root)
        let observed = log.onMainThread.withLock { $0 }
        #expect(observed.count == Support.inspectableFiles.count + 1)
        #expect(!observed.contains(true))
    }
}
