import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of `LegacyMigrationArchive`: the package it builds, the names it may mutate, what it refuses and the disk
/// entry. Crashes, faults and changed sources are in `ProjectMigrationTests+ArchiveCrash.swift`.
extension ProjectMigrationTests {
    enum Archive {
        static let projectID = ProjectID(validated: "prj.legacy")
        static let destination = "LegacyMigration.fluxklang"
        static let staging = ".LegacyMigration.fluxklang.staging-legacy1"

        static func policy() throws -> ProjectPackageManifestPolicy {
            try ProjectPackageManifestPolicy(packageLimits: Fixture.limits(), maxManifestBytes: 65_536)
        }

        static func run(
            _ store: inout InMemoryStagingFileSystem, projectID: ProjectID = projectID
        ) throws -> LegacyMigrationArchiveOutcome {
            LegacyMigrationArchive.archive(in: &store, projectID: projectID, policy: try policy())
        }

        static func archived(_ outcome: LegacyMigrationArchiveOutcome) -> LegacyMigrationReceipt? {
            if case .archived(let receipt) = outcome { return receipt }
            return nil
        }

        static func read(_ store: inout some StagingFileSystem) throws -> ProjectPackageContents {
            try StagedPackageImport.read(
                from: destination, policy: policy(), chunkByteCount: StagedPackageImport.defaultChunkByteCount,
                in: &store
            )
        }

        static func file(_ path: String, in contents: ProjectPackageContents) -> Data? {
            contents.files.first { $0.path == path }?.bytes
        }

        /// Every node outside the archive's two names: the legacy files and any neighbour, identity and generation too.
        static func untouched(_ store: InMemoryStagingFileSystem) -> [String: InMemoryStagingFileSystem.Node] {
            store.nodes(outside: [destination, staging])
        }

        static func project(_ contents: ProjectPackageContents) throws -> ProjectDocument {
            try ProjectDocument.decode(from: #require(file(LegacyMigrationArchive.projectPath, in: contents)))
        }

        static func record(_ contents: ProjectPackageContents) throws -> [String: JSONValue] {
            guard case .object(let record)? = try project(contents).extensions?["legacyMigration"] else { return [:] }
            return record
        }

        static func state(_ value: String, kind: String? = nil) -> JSONValue {
            var fields: [String: JSONValue] = ["state": .string(value)]
            if let kind { fields["kind"] = .string(kind) }
            return .object(fields)
        }

        /// The archive's production files, read from the checkout or from the package mirror; empty when absent.
        static func archiveSources() -> [String] {
            let names = ["LegacyMigrationArchive.swift", "LegacyMigrationArchiveOutcome.swift"]
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let relative = "Shared/Persistence/Adoption/Migration/"
            let parent = folder.deletingLastPathComponent()
            for root in [parent, parent.deletingLastPathComponent()] {
                for prefix in ["", "Sources/FluxKlang/"] {
                    let directory = root.appendingPathComponent(prefix + relative)
                    let texts = names.compactMap {
                        try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
                    }
                    if texts.count == names.count { return texts }
                }
            }
            return []
        }

        static func inode(_ url: URL) -> stat? {
            var info = stat()
            return lstat(url.path, &info) == 0 ? info : nil
        }
    }

    @Test
    func archivesAdoptedPartsByteExactAndVerifies() throws {
        var store = Legacy.volume()
        let outcome = try Archive.run(&store)
        let receipt = try #require(Archive.archived(outcome))
        #expect(receipt.archived == [.connections, .usbMap, .pendingDraft])
        let found = try Archive.read(&store)
        let expected: [(String, Data)] = [
            (LegacyMigrationArchive.connectionsPath, Fixture.connectionsBytes),
            (LegacyMigrationArchive.usbMapPath, Fixture.usbMapBytes),
            (LegacyMigrationArchive.draftPath, Fixture.draftBytes)
        ]
        for (path, bytes) in expected {
            #expect(Archive.file(path, in: found).map { Array($0) } == Array(bytes), "\(path)")
        }
        #expect(found.manifest.opaqueState.map(\.path) == expected.map(\.0))
        #expect(found.files.filter { $0.role == .opaqueState }.count == 3)
        #expect(found.manifest.graphs.isEmpty)
        #expect(try Archive.project(found).graphs.isEmpty)
        let built = try LegacyMigrationArchive.contents(
            receipt.report, projectID: Archive.projectID, policy: Archive.policy()
        )
        #expect(found.manifestBytes == built?.manifestBytes)
        #expect(found.directories == built?.directories)
        #expect(found.files == built?.files)
        #expect(store.shapes(at: Archive.staging).isEmpty)
    }

    @Test
    func archiveNeverMutatesALegacyName() throws {
        var store = Legacy.volume()
        store.seedFile("neighbour.json", Data("{}".utf8))
        store.seedDirectory(Archive.staging)
        store.seedFile(Archive.staging + "/leftover", Data([1]))
        let before = Archive.untouched(store)
        #expect(Archive.archived(try Archive.run(&store)) != nil)
        func isOurs(_ path: String) -> Bool {
            StagingPlan.isWithin(path, of: Archive.destination) || StagingPlan.isWithin(path, of: Archive.staging)
        }
        #expect(store.mutations.contains { $0.operation == .removeNode(Archive.staging) })
        for entry in store.mutations {
            switch entry.operation {
            case .makeDirectory(let path), .createFile(let path, _), .removeNode(let path):
                #expect(isOurs(path), "\(entry.operation)")
            case .syncDirectory(let path):
                #expect(path.isEmpty || isOurs(path), "\(entry.operation)")
            case .rename(let source, let target):
                #expect(source == Archive.staging && target == Archive.destination, "\(entry.operation)")
            case .status, .list, .read:
                Issue.record("not mutating: \(entry.operation)")
            }
        }
        #expect(Archive.untouched(store) == before)
        for source in ProjectMigrationSource.allCases {
            #expect(store.nodes[Legacy.name(source)]?.bytes == Fixture.valid(source))
        }
    }

    @Test
    func refusedAndMissingSourcesAreNotArchived() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Fixture.connectionsBytes
        var store = Legacy.volume([Legacy.connections: bom, Legacy.draft: Fixture.draftBytes])
        let receipt = try #require(Archive.archived(try Archive.run(&store)))
        #expect(receipt.archived == [.pendingDraft])
        let found = try Archive.read(&store)
        #expect(found.files.map(\.path) == [LegacyMigrationArchive.draftPath, LegacyMigrationArchive.projectPath])
        for file in found.files {
            #expect(file.bytes.range(of: Data([0xEF, 0xBB, 0xBF])) == nil, "\(file.path)")
            #expect(file.bytes.range(of: Data(#""temporaryMoves""#.utf8)) == nil, "\(file.path)")
        }
        let sources: JSONValue = .object([
            "connections": Archive.state("refused", kind: "migration.undecodable"),
            "usbMap": Archive.state("missing"), "pendingDraft": Archive.state("adopted")
        ])
        #expect(try Archive.record(found)["sources"] == sources)
        #expect(store.nodes[Legacy.connections]?.bytes == bom)
    }

    @Test
    func nothingAdoptedWritesNothing() throws {
        let policy = try Archive.policy()
        #expect(try LegacyMigrationArchive.contents(.uniform(nil), projectID: Archive.projectID, policy: policy) == nil)
        let volumes = [
            Legacy.volume([:]),
            Legacy.volume([Legacy.connections: Fixture.text("{}"), Legacy.draft: Fixture.text("[]")])
        ]
        for start in volumes {
            var store = start
            let outcome = try Archive.run(&store)
            guard case .nothingToArchive(let report) = outcome else {
                Issue.record("unexpected \(outcome)")
                continue
            }
            #expect(Legacy.adopted(report, .connections) == nil)
            #expect(store.mutations.isEmpty)
            #expect(store.nodes == start.nodes)
        }
    }

    @Test
    func draftProvenanceIsInvalidated() throws {
        var store = Legacy.volume()
        _ = try #require(Archive.archived(try Archive.run(&store)))
        let found = try Archive.read(&store)
        let project = try Archive.project(found)
        let invalidated: JSONValue = .object([
            "source": .string("PendingStudioDraft"), "authority": .string("invalidated"), "reviewRequired": .bool(true)
        ])
        #expect(project.extensions?["provenance"] == invalidated)
        #expect(project.id == Archive.projectID)
        let record = try Archive.record(found)
        let draft: JSONValue = .object([
            "id": .string(Fixture.draftID.uppercased()), "createdAt": .double(800_000_000.5)
        ])
        #expect(record["draft"] == draft)
        #expect(record["homeWiring"] == .object(["freshness": .string("localFile")]))
        let adopted = Archive.state("adopted")
        #expect(record["sources"] == .object(["connections": adopted, "usbMap": adopted, "pendingDraft": adopted]))
    }

    @Test
    func onlyTheDraftIsRetirable() throws {
        var full = Legacy.volume()
        let receipt = try #require(Archive.archived(try Archive.run(&full)))
        #expect(receipt.retirable == [.pendingDraft])
        var noDraft = Legacy.volume([Legacy.connections: Fixture.connectionsBytes, Legacy.usbMap: Fixture.usbMapBytes])
        let partial = try #require(Archive.archived(try Archive.run(&noDraft)))
        #expect(partial.archived == [.connections, .usbMap])
        #expect(partial.retirable.isEmpty)
    }

    @Test
    func identicalArchiveIsAlreadyArchivedWithoutWrites() throws {
        var store = Legacy.volume()
        let first = try #require(Archive.archived(try Archive.run(&store)))
        let archive = store.shapes(at: Archive.destination)
        store.arm()
        let mark = store.log.count
        let outcome = try Archive.run(&store)
        #expect(outcome == .alreadyArchived(first))
        #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating })
        #expect(store.shapes(at: Archive.destination) == archive)
    }

    @Test
    func differingArchiveIsRefusedNotOverwritten() throws {
        var store = Legacy.volume([Legacy.connections: Fixture.connectionsBytes])
        _ = try #require(Archive.archived(try Archive.run(&store)))
        store.seedFile(Legacy.usbMap, Fixture.usbMapBytes)
        var other = store
        let archive = store.nodes.filter { StagingPlan.isWithin($0.key, of: Archive.destination) }
        store.arm()
        let mark = store.log.count
        #expect(try Archive.run(&store) == .refused(.archiveDiffers))
        #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating })
        #expect(store.nodes.filter { StagingPlan.isWithin($0.key, of: Archive.destination) } == archive)

        other.unseed(Legacy.usbMap)
        other.arm()
        let otherMark = other.log.count
        #expect(try Archive.run(&other, projectID: ProjectID(validated: "prj.other")) == .refused(.archiveDiffers))
        #expect(other.log.dropFirst(otherMark).allSatisfy { !$0.operation.isMutating })

        var file = Legacy.volume()
        file.seedFile(Archive.destination, Data("not a package".utf8))
        let before = file.nodes
        #expect(try Archive.run(&file) == .refused(.archiveDiffers))
        #expect(file.mutations.isEmpty)
        #expect(file.nodes == before)
    }

    @Test
    func diskArchiveRoundTripLeavesOriginalInodeMtime() throws {
        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = scratch.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try Legacy.write(Dictionary(uniqueKeysWithValues: ProjectMigrationSource.allCases.map {
            (Legacy.name($0), Fixture.valid($0))
        }), in: app)
        let urls = ProjectMigrationSource.allCases.map { app.appendingPathComponent(Legacy.name($0)) }
        let before = try urls.map { try #require(Archive.inode($0)) }
        let policy = try Archive.policy()

        let outcome = LegacyMigrationArchive.archive(directory: app, projectID: Archive.projectID, policy: policy)
        let receipt = try #require(Archive.archived(outcome))
        #expect(receipt.retirable == [.pendingDraft])
        var disk = try DiskStagingFileSystem(root: app, limits: policy.packageLimits)
        let found = try Archive.read(&disk)
        disk.close()
        let usbMap = Archive.file(LegacyMigrationArchive.usbMapPath, in: found)
        #expect(usbMap.map { Array($0) } == Array(Fixture.usbMapBytes))
        let again = LegacyMigrationArchive.archive(directory: app, projectID: Archive.projectID, policy: policy)
        #expect(again == .alreadyArchived(receipt))
        for (index, url) in urls.enumerated() {
            let after = try #require(Archive.inode(url))
            #expect(after.st_ino == before[index].st_ino)
            #expect(after.st_mtimespec.tv_sec == before[index].st_mtimespec.tv_sec)
            #expect(after.st_mtimespec.tv_nsec == before[index].st_mtimespec.tv_nsec)
            #expect(after.st_ctimespec.tv_sec == before[index].st_ctimespec.tv_sec)
            #expect(after.st_ctimespec.tv_nsec == before[index].st_ctimespec.tv_nsec)
            #expect(Array(try Data(contentsOf: url)) == Array(Fixture.valid(ProjectMigrationSource.allCases[index])))
        }
        let listing = try FileManager.default.contentsOfDirectory(atPath: app.path).sorted()
        #expect(listing == (ProjectMigrationSource.allCases.map(Legacy.name) + [Archive.destination]).sorted())

        let link = scratch.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let linked = LegacyMigrationArchive.archive(directory: link, projectID: Archive.projectID, policy: policy)
        guard case .refused(.staging) = linked else {
            Issue.record("a symlinked root was not refused: \(linked)")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.path).sorted() == listing)
    }

    /// A missing app directory is every source missing, as the reader treats it: nothing to archive, nothing created.
    @Test
    func diskMissingDirectoryIsNothingToArchive() throws {
        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appendingPathComponent("absent", isDirectory: true)
        let outcome = LegacyMigrationArchive.archive(
            directory: missing, projectID: Archive.projectID, policy: try Archive.policy()
        )
        #expect(outcome == .nothingToArchive(.uniform(nil)))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    /// The archive's sources name no store, cloud type or link-following file API; it works only through the protocol.
    @Test
    func archiveSourcesNameNoStoreOrCloudType() {
        let sources = Archive.archiveSources()
        #expect(sources.count == 2)
        let banned = [
            "JSONFileStore", "CloudKeyValueStore", "CloudStore", "Ubiquitous", "AppPersistence", "contentsOf",
            "FileManager", "FileHandle", "NSData", "fopen", "Data(contentsOf", "replaceExisting", "removeTree"
        ]
        for text in sources {
            for word in banned { #expect(!text.contains(word), "\(word)") }
        }
    }
}
