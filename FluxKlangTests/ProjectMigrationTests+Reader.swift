import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of `LegacySourceReader`: the in-memory volume pins the check order, the primitives used and the faults;
/// a per-test temporary directory pins links, the missing directory and untouched originals on disk.
extension ProjectMigrationTests {
    enum Legacy {
        static let connections = "studio-connections.json"
        static let usbMap = "launch-control-xl.json"
        static let draft = "assistant-pending-studio-draft.json"

        static func name(_ source: ProjectMigrationSource) -> String {
            switch source {
            case .connections: connections
            case .usbMap: usbMap
            case .pendingDraft: draft
            }
        }

        /// A volume holding the three valid fixtures, or `files` when given.
        static func volume(_ files: [String: Data]? = nil) -> InMemoryStagingFileSystem {
            var store = InMemoryStagingFileSystem()
            let seeded = files ?? Dictionary(uniqueKeysWithValues: ProjectMigrationSource.allCases.map {
                (name($0), Fixture.valid($0))
            })
            for (path, bytes) in seeded { store.seedFile(path, bytes) }
            return store
        }

        static func refusal(_ report: LegacySourceReport, _ source: ProjectMigrationSource) -> LegacySourceRefusal? {
            switch source {
            case .connections: refused(report.homeWiring)
            case .usbMap: refused(report.hostLocal)
            case .pendingDraft: refused(report.draft)
            }
        }

        static func refused<Value>(_ outcome: LegacySourceOutcome<Value>) -> LegacySourceRefusal? {
            guard case .refused(let refusal) = outcome else { return nil }
            return refusal
        }

        static func adopted(_ report: LegacySourceReport, _ source: ProjectMigrationSource) -> Data? {
            switch (source, report.homeWiring, report.hostLocal, report.draft) {
            case (.connections, .adopted(let part), _, _), (.usbMap, _, .adopted(let part), _): part.original
            case (.pendingDraft, _, _, .adopted(let draft)): draft.original
            default: nil
            }
        }

        static func reads(_ store: InMemoryStagingFileSystem, _ path: String) -> [InMemoryStagingFileSystem.FileOp] {
            store.log.map(\.operation).filter {
                if case .read(path, _, _) = $0 { return true }
                return false
            }
        }

        static func scratch() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LegacySourceReaderTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }

        static func write(_ files: [String: Data], in directory: URL) throws {
            for (name, bytes) in files { try bytes.write(to: directory.appendingPathComponent(name)) }
        }

        static func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }

        /// The reader's production files, read from the checkout or from the package mirror; empty when absent.
        static func readerSources() -> [String] {
            let names = ["LegacySourceReader.swift", "LegacySourceReadOutcome.swift"]
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
    }

    @Test
    func readsAllThreeLocalFilesAndAdoptsByteExact() throws {
        let limits = try Fixture.limits()
        var store = Legacy.volume()
        let report = LegacySourceReader.read(in: &store, limits: limits)
        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Legacy.write(Dictionary(uniqueKeysWithValues: ProjectMigrationSource.allCases.map {
            (Legacy.name($0), Fixture.valid($0))
        }), in: scratch)
        let disk = LegacySourceReader.read(directory: scratch, limits: limits)
        #expect(disk == report)
        for source in ProjectMigrationSource.allCases {
            let bytes = try #require(Legacy.adopted(report, source))
            #expect(Array(bytes) == Array(Fixture.valid(source)))
        }
        guard case .adopted(let draft) = report.draft else { Issue.record("draft not adopted"); return }
        #expect(draft.id.uuidString.lowercased() == Fixture.draftID)
        #expect(draft.provenance == MigratedDraft.provenance)
    }

    @Test
    func missingFilesAreMissingNotRefused() throws {
        let limits = try Fixture.limits()
        var empty = InMemoryStagingFileSystem()
        #expect(LegacySourceReader.read(in: &empty, limits: limits) == .uniform(nil))
        var onlyUSB = Legacy.volume([Legacy.usbMap: Fixture.usbMapBytes])
        let partial = LegacySourceReader.read(in: &onlyUSB, limits: limits)
        #expect(partial.homeWiring == .missing)
        #expect(partial.draft == .missing)
        #expect(Legacy.adopted(partial, .usbMap) == Fixture.usbMapBytes)

        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let absent = scratch.appendingPathComponent("absent", isDirectory: true)
        #expect(LegacySourceReader.read(directory: absent, limits: limits) == .uniform(nil))
        let deeper = absent.appendingPathComponent("deeper", isDirectory: true)
        #expect(LegacySourceReader.read(directory: deeper, limits: limits) == .uniform(nil))
        #expect(!Legacy.exists(absent))
        #expect(LegacySourceReader.read(directory: scratch, limits: limits) == .uniform(nil))
    }

    @Test
    func refusedSourceLeavesOriginalBytesAndMtimeUntouched() throws {
        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bom = Data([0xEF, 0xBB, 0xBF]) + Fixture.connectionsBytes
        let file = scratch.appendingPathComponent(Legacy.connections)
        try Legacy.write([Legacy.connections: bom, Legacy.usbMap: Fixture.usbMapBytes], in: scratch)
        var before = stat()
        #expect(lstat(file.path, &before) == 0)
        let listing = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()

        let report = LegacySourceReader.read(directory: scratch, limits: try Fixture.limits())
        let undecodable = ProjectMigrationRefusal(source: .connections, kind: .undecodable)
        #expect(report.homeWiring == .refused(.migration(undecodable)))
        #expect(Legacy.adopted(report, .usbMap) == Fixture.usbMapBytes)

        var after = stat()
        #expect(lstat(file.path, &after) == 0)
        #expect(Array(try Data(contentsOf: file)) == Array(bom))
        #expect(after.st_ino == before.st_ino)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        #expect(after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec)
        #expect(after.st_size == before.st_size)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == listing)
    }

    @Test
    func readerIssuesNoMutatingPrimitive() throws {
        var store = Legacy.volume([
            Legacy.connections: Fixture.connectionsBytes, Legacy.usbMap: Fixture.text("{}"),
            Legacy.draft: Fixture.padded(Fixture.draftBytes, to: 2001)
        ])
        store.seedNode("other.json", kind: .symbolicLink)
        let before = store.nodes
        let limits = try Fixture.limits(entryBytes: 2000, totalBytes: 10_000)
        let report = LegacySourceReader.read(in: &store, limits: limits)
        #expect(Legacy.adopted(report, .connections) != nil)
        #expect(Legacy.refusal(report, .usbMap) != nil)
        #expect(Legacy.refusal(report, .pendingDraft) != nil)
        #expect(store.mutations.isEmpty)
        #expect(store.nodes == before)
        for entry in store.log {
            switch entry.operation {
            case .status, .read: continue
            default: Issue.record("unexpected primitive \(entry.operation)")
            }
        }
    }

    @Test
    func overLimitFileIsOversizedWithoutRead() throws {
        let limits = try Fixture.limits(entryBytes: 2000, totalBytes: 10_000)
        for source in ProjectMigrationSource.allCases {
            let name = Legacy.name(source)
            var over = Legacy.volume([name: Fixture.padded(Fixture.valid(source), to: 2001)])
            let report = LegacySourceReader.read(in: &over, limits: limits)
            let oversized = ProjectMigrationRefusal(source: source, kind: .oversized)
            #expect(Legacy.refusal(report, source) == .migration(oversized))
            #expect(Legacy.reads(over, name).isEmpty)

            let atLimit = Fixture.padded(Fixture.valid(source), to: 2000)
            var exact = Legacy.volume([name: atLimit])
            #expect(Legacy.adopted(LegacySourceReader.read(in: &exact, limits: limits), source) == atLimit)
            #expect(Legacy.reads(exact, name) == [.read(name, 0, 2001)])
        }
    }

    @Test
    func symlinkToOutsideFileIsRefused() throws {
        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let outside = scratch.appendingPathComponent("outside.json")
        try Fixture.connectionsBytes.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(Legacy.connections), withDestinationURL: outside
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(Legacy.usbMap), withIntermediateDirectories: false
        )
        let report = LegacySourceReader.read(directory: root, limits: try Fixture.limits())
        #expect(report.homeWiring == .refused(.io(.notRegularFile)))
        #expect(report.hostLocal == .refused(.io(.notRegularFile)))
        #expect(report.draft == .missing)
        #expect(try Data(contentsOf: outside) == Fixture.connectionsBytes)

        var store = Legacy.volume([:])
        store.seedNode(Legacy.connections, kind: .symbolicLink)
        let fake = LegacySourceReader.read(in: &store, limits: try Fixture.limits())
        #expect(fake.homeWiring == .refused(.io(.notRegularFile)))
        #expect(Legacy.reads(store, Legacy.connections).isEmpty)
    }

    @Test
    func symlinkedRootDirectoryIsRefused() throws {
        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let real = scratch.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try Legacy.write([Legacy.connections: Fixture.connectionsBytes], in: real)
        let link = scratch.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let limits = try Fixture.limits()
        #expect(LegacySourceReader.read(directory: link, limits: limits) == .uniform(.io(.directoryRefused)))
        let file = scratch.appendingPathComponent("file")
        try Fixture.connectionsBytes.write(to: file)
        #expect(LegacySourceReader.read(directory: file, limits: limits) == .uniform(.io(.directoryRefused)))
        let beneathLink = link.appendingPathComponent("inner", isDirectory: true)
        let inner = real.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        #expect(LegacySourceReader.read(directory: beneathLink, limits: limits) == .uniform(.io(.directoryRefused)))
        #expect(Legacy.adopted(LegacySourceReader.read(directory: real, limits: limits), .connections) != nil)
    }

    @Test
    func hardLinkedOrOtherVolumeIsRefused() throws {
        var store = InMemoryStagingFileSystem()
        store.seedFile(Legacy.connections, Fixture.connectionsBytes, linkCount: 2)
        store.seedFile(Legacy.usbMap, Fixture.usbMapBytes, volume: 2)
        store.seedFile(Legacy.draft, Fixture.draftBytes)
        let report = LegacySourceReader.read(in: &store, limits: try Fixture.limits())
        #expect(report.homeWiring == .refused(.io(.hardLinked)))
        #expect(report.hostLocal == .refused(.io(.otherVolume)))
        #expect(Legacy.adopted(report, .pendingDraft) == Fixture.draftBytes)
        #expect(Legacy.reads(store, Legacy.connections).isEmpty)
        #expect(Legacy.reads(store, Legacy.usbMap).isEmpty)

        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Legacy.write([Legacy.usbMap: Fixture.usbMapBytes], in: scratch)
        try FileManager.default.linkItem(
            at: scratch.appendingPathComponent(Legacy.usbMap), to: scratch.appendingPathComponent("second-name")
        )
        let disk = LegacySourceReader.read(directory: scratch, limits: try Fixture.limits())
        #expect(disk.hostLocal == .refused(.io(.hardLinked)))
    }

    /// Two or more defects at once: the earlier check wins (kind, then links, then volume, then size) and none reads.
    @Test
    func earlierCheckWinsWhenDefectsCombine() throws {
        let limits = try Fixture.limits(entryBytes: 2000, totalBytes: 10_000)
        var store = InMemoryStagingFileSystem()
        let over = { (source: ProjectMigrationSource) in Fixture.padded(Fixture.valid(source), to: 2001) }
        store.seedFile(Legacy.connections, over(.connections), linkCount: 2, volume: 2)
        store.seedFile(Legacy.usbMap, over(.usbMap), volume: 2)
        store.seedFile(Legacy.draft, over(.pendingDraft), linkCount: 2, volume: 2)
        // Retype the draft in place: an empty read past its end turns it into a link that keeps its links and volume.
        store.arm(InMemoryStagingFileSystem.Script(mutateOnRead: [Legacy.draft: .changeKind]))
        _ = try store.read(at: Legacy.draft, offset: 2001, count: 1)
        let retyped = try #require(try store.status(at: Legacy.draft))
        #expect(retyped.kind == .symbolicLink && retyped.linkCount == 2 && retyped.volume == 2)
        #expect(retyped.byteCount == 2001)
        store.arm()
        let mark = store.log.count

        let report = LegacySourceReader.read(in: &store, limits: limits)
        #expect(report.homeWiring == .refused(.io(.hardLinked)))
        #expect(report.hostLocal == .refused(.io(.otherVolume)))
        #expect(report.draft == .refused(.io(.notRegularFile)))
        for entry in store.log.dropFirst(mark) {
            if case .read = entry.operation { Issue.record("unexpected \(entry.operation)") }
        }
    }

    /// A positive status followed by a vanished, relinked or swapped file is `changed`, never a plain failure.
    @Test
    func faultAfterPositiveStatusIsChanged() throws {
        let limits = try Fixture.limits()
        // Log indexes: 0 the root status, 1 the first status, 2 the read, 3 the second status (of connections).
        let cases: [(StagingIOFault, Int)] = [
            (.notFound, 2), (.notFound, 3), (.changed, 1), (.changed, 2), (.changed, 3)
        ]
        let read = InMemoryStagingFileSystem.FileOp.read(Legacy.connections, 0, ProjectMigration.entryLimit(limits) + 1)
        for (fault, index) in cases {
            var store = Legacy.volume()
            store.arm(.fault(fault, at: index))
            let report = LegacySourceReader.read(in: &store, limits: limits)
            #expect(report.homeWiring == .refused(.io(.changed)), "\(fault) at \(index)")
            #expect(store.log[index].outcome == .fault(fault))
            #expect((store.log[index].operation == read) == (index == 2))
            #expect(Legacy.adopted(report, .usbMap) == Fixture.usbMapBytes)
            #expect(Legacy.adopted(report, .pendingDraft) == Fixture.draftBytes)
        }
    }

    @Test
    func changedDuringReadIsRefused() throws {
        let limits = try Fixture.limits()
        let mutations: [InMemoryStagingFileSystem.ReadMutation] = [
            .bumpGeneration, .appendByte, .addLink, .changeVolume
        ]
        for mutation in mutations {
            var store = Legacy.volume()
            store.arm(InMemoryStagingFileSystem.Script(mutateOnRead: [Legacy.usbMap: mutation]))
            let report = LegacySourceReader.read(in: &store, limits: limits)
            #expect(report.hostLocal == .refused(.io(.changed)), "\(mutation)")
            #expect(Legacy.adopted(report, .connections) == Fixture.connectionsBytes)
            #expect(Legacy.adopted(report, .pendingDraft) == Fixture.draftBytes)
        }
        for skew in [1, -1] {
            var store = Legacy.volume()
            store.arm(InMemoryStagingFileSystem.Script(statusSizeSkew: [Legacy.draft: skew]))
            let report = LegacySourceReader.read(in: &store, limits: limits)
            #expect(report.draft == .refused(.io(.changed)), "\(skew)")
        }
        var faulty = Legacy.volume()
        faulty.arm(.fault(.denied, at: 1))
        #expect(LegacySourceReader.read(in: &faulty, limits: limits).homeWiring == .refused(.io(.failed(.denied))))
    }

    @Test
    func strictDecodeMismatchIsReportedPerSource() throws {
        let duplicate = Fixture.text(
            #"{"version":1,"version":1,"mode":"control","mapping":{}}"#
        )
        var store = Legacy.volume([
            Legacy.connections: Fixture.connectionsBytes, Legacy.usbMap: duplicate, Legacy.draft: Fixture.draftBytes
        ])
        let before = store.nodes
        let report = LegacySourceReader.read(in: &store, limits: try Fixture.limits())
        #expect(report.hostLocal == .refused(.migration(ProjectMigrationRefusal(source: .usbMap, kind: .undecodable))))
        #expect(Legacy.adopted(report, .connections) == Fixture.connectionsBytes)
        #expect(Legacy.adopted(report, .pendingDraft) == Fixture.draftBytes)
        #expect(store.nodes == before)
    }

    @Test
    func fileNamesMatchStorageInventory() throws {
        let limits = try Fixture.limits()
        let fileKinds: [StorageSurface.Kind] = [.storeFile, .localFile]
        for source in ProjectMigrationSource.allCases {
            let names = StorageInventory.shipped.filter {
                $0.storageClass == source.storageClass && fileKinds.contains($0.surface.kind)
                    && $0.surface.name.hasSuffix(".json")
            }.map(\.surface.name)
            #expect(names.count == 1)
            let name = try #require(names.first)
            #expect(name == Legacy.name(source))
            var store = Legacy.volume([name: Fixture.valid(source)])
            let report = LegacySourceReader.read(in: &store, limits: limits)
            #expect(Legacy.adopted(report, source) == Fixture.valid(source))
            for other in ProjectMigrationSource.allCases where other != source {
                #expect(Legacy.adopted(report, other) == nil)
                #expect(Legacy.refusal(report, other) == nil)
            }
        }
    }

    /// The reader's sources name no store, cloud type or link-following file API; it reads only through the protocol.
    @Test
    func readerSourcesNameNoStoreOrCloudType() {
        let sources = Legacy.readerSources()
        #expect(sources.count == 2)
        let banned = [
            "JSONFileStore", "CloudKeyValueStore", "CloudStore", "Ubiquitous", "AppPersistence", "contentsOf",
            "FileManager", "FileHandle", "NSData", "fopen", "Data(contentsOf"
        ]
        for text in sources {
            for word in banned { #expect(!text.contains(word), "\(word)") }
        }
    }
}
