import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Staged package export/import over the in-memory fake volume. Topics live in `ProjectStagingTests+*.swift`.
@Suite(.productionAccessAudit)
struct ProjectStagingTests {
    typealias Fake = InMemoryStagingFileSystem

    enum Fixture {
        static let destination = "Set.fluxklang"
        static let source = "source.fluxklang"
        static let token = "t1"
        static let staging = ".Set.fluxklang.staging-t1"
        static let backup = ".Set.fluxklang.previous-t1"
        /// SHA-256 of the ASCII bytes "abc".
        static let abcDigest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        static func limits(
            entries: Int = 32, depth: Int = 6, pathBytes: Int = 120, entryBytes: Int = 4096, totalBytes: Int = 16_384
        ) throws -> ProjectPackageLimits {
            try ProjectPackageLimits(
                maxEntries: entries, maxDepth: depth, maxPathUTF8Bytes: pathBytes,
                maxEntryBytes: entryBytes, maxTotalBytes: totalBytes
            )
        }

        static func policy(
            entries: Int = 32, depth: Int = 6, entryBytes: Int = 4096, totalBytes: Int = 16_384,
            manifestBytes: Int = 2048
        ) throws -> ProjectPackageManifestPolicy {
            try ProjectPackageManifestPolicy(
                packageLimits: limits(entries: entries, depth: depth, entryBytes: entryBytes, totalBytes: totalBytes),
                maxManifestBytes: manifestBytes
            )
        }

        static func manifestBytes(_ spec: StagingFixtureSpec, policy: ProjectPackageManifestPolicy) throws -> Data {
            var files = spec.files
            files["project.json"] = spec.project
            files["graphs/main.json"] = spec.graph
            func member(_ path: String) -> ProjectPackageMember {
                ProjectPackageMember(path: path, byteCount: spec.declared ? files[path]?.count : nil)
            }
            var resources: [ProjectPackageResource] = []
            if let digest = spec.mediaDigest {
                resources = [ProjectPackageResource(
                    contentDigest: digest, media: member("media/click.wav"), bookmarks: []
                )]
            }
            let manifest = ProjectPackageManifest(
                project: ProjectPackageProjectReference(
                    id: ProjectID(validated: "prj.set"), revision: .initial, member: member("project.json")
                ),
                graphs: spec.graph == nil ? [] : [ProjectPackageGraphReference(
                    graph: GraphID(validated: "gph.main"), revision: .initial, member: member("graphs/main.json")
                )],
                resources: resources, opaqueState: spec.opaque.map(member)
            )
            return try manifest.encoded(policy: policy)
        }

        static func contents(
            _ spec: StagingFixtureSpec, policy: ProjectPackageManifestPolicy? = nil
        ) throws -> ProjectPackageContents {
            let policy = try policy ?? Self.policy()
            var files = spec.files
            files["project.json"] = spec.project
            files["graphs/main.json"] = spec.graph
            return try ProjectPackageContents(
                manifestBytes: manifestBytes(spec, policy: policy), directories: spec.directories, files: files,
                policy: policy
            )
        }

        /// 4 directories (one empty), 4 files: project, graph, unlisted note, opaque state.
        static func big(_ marker: String, declared: Bool = true) throws -> ProjectPackageContents {
            try contents(StagingFixtureSpec(
                project: Data("P-\(marker)".utf8), graph: Data("G-\(marker)".utf8),
                directories: ["empty", "graphs", "notes", "state"],
                files: ["notes/readme.txt": Data("keep".utf8), "state/draft.bin": Data([0xFF, 0x00, 0xFE])],
                opaque: ["state/draft.bin"], declared: declared
            ))
        }

        /// 1 directory, 2 files (project, one unlisted file inside the directory).
        static func tiny(_ marker: String) throws -> ProjectPackageContents {
            try contents(StagingFixtureSpec(
                project: Data("P-\(marker)".utf8), directories: ["d"], files: ["d/a": Data([1, 2, 3])]
            ))
        }

        static func plan(
            _ mode: StagingMode, destination: String = destination, token: String = token,
            ceiling: Int = StagingPlan.maximumOperations
        ) throws -> StagingPlan {
            try StagingPlan.make(
                destination: destination, token: token, mode: mode, limits: limits(), operationCeiling: ceiling
            )
        }

        /// A volume with unrelated neighbours, an optional old package at the destination and a source package.
        static func volume(old: ProjectPackageContents? = nil, source: ProjectPackageContents? = nil) -> Fake {
            var fake = Fake()
            fake.seedDirectory("other")
            fake.seedFile("other/keep", Data("keep".utf8))
            fake.seedFile("sibling.txt", Data([9]))
            if let old { fake.seed(package: old, at: destination) }
            if let source { fake.seed(package: source, at: Self.source) }
            return fake
        }

        static func export(
            _ plan: StagingPlan, _ contents: ProjectPackageContents, _ fake: inout Fake
        ) -> Result<StagingReceipt, StagingRefusal> {
            do throws(StagingRefusal) {
                return try .success(StagedPackageExport.run(plan: plan, contents: contents, in: &fake))
            } catch {
                return .failure(error)
            }
        }

        static func importRun(
            _ plan: StagingPlan, from path: String = source, policy: ProjectPackageManifestPolicy? = nil,
            chunk: Int = StagedPackageImport.defaultChunkByteCount, _ fake: inout Fake
        ) throws -> Result<StagingReceipt, StagingRefusal> {
            let policy = try policy ?? Self.policy()
            do throws(StagingRefusal) {
                return try .success(StagedPackageImport.run(
                    from: path, plan: plan, policy: policy, chunkByteCount: chunk, in: &fake
                ))
            } catch {
                return .failure(error)
            }
        }

        static func read(
            _ path: String = source, policy: ProjectPackageManifestPolicy? = nil,
            chunk: Int = StagedPackageImport.defaultChunkByteCount, _ fake: inout Fake
        ) throws -> Result<ProjectPackageContents, StagingRefusal> {
            let policy = try policy ?? Self.policy()
            do throws(StagingRefusal) {
                return try .success(
                    StagedPackageImport.read(from: path, policy: policy, chunkByteCount: chunk, in: &fake)
                )
            } catch {
                return .failure(error)
            }
        }

        static func recover(
            _ plan: StagingPlan, _ fake: inout Fake
        ) -> Result<[StagingRecoveryOutcome], StagingRefusal> {
            do throws(StagingRefusal) {
                return try .success(StagingRecovery.recover(plan: plan, in: &fake))
            } catch {
                return .failure(error)
            }
        }

        static func refusal<Value>(_ result: Result<Value, StagingRefusal>) -> StagingRefusal? {
            if case let .failure(error) = result { return error }
            return nil
        }

        static func value<Value>(_ result: Result<Value, StagingRefusal>) -> Value? {
            if case let .success(value) = result { return value }
            return nil
        }

        /// The package paths used for a name in the expected-shape maps.
        static func shapes(_ contents: ProjectPackageContents) -> [String: Fake.Shape] {
            Fake.shapes(of: contents)
        }
    }
}

struct StagingFixtureSpec {
    var project = Data("P".utf8)
    var graph: Data?
    var directories: [String] = []
    var files: [String: Data] = [:]
    var opaque: [String] = []
    var mediaDigest: String?
    var declared = true
}
