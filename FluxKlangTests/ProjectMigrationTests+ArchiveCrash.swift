import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `LegacyMigrationArchive` under changed sources, IO faults, a crash at every operation of a run, a tampered or
/// unreadable archive and each refusal before a write.
extension ProjectMigrationTests {
    /// The log of an unfaulted archive run from `start`, and the archive's expected shapes.
    private func cleanRun(
        _ start: InMemoryStagingFileSystem
    ) throws -> (log: [InMemoryStagingFileSystem.Entry], shapes: [String: InMemoryStagingFileSystem.Shape]) {
        var store = start
        let receipt = try #require(Archive.archived(try Archive.run(&store)))
        let built = try #require(try LegacyMigrationArchive.contents(
            receipt.report, projectID: Archive.projectID, policy: Archive.policy()
        ))
        let shapes = store.shapes(at: Archive.destination)
        #expect(shapes == InMemoryStagingFileSystem.shapes(of: built))
        return (store.log, shapes)
    }

    private func crashes(for entry: InMemoryStagingFileSystem.Entry) -> [InMemoryStagingFileSystem.Crash] {
        guard case let .createFile(_, count) = entry.operation else { return [.before, .after] }
        return [.before, .after] + Array(Set([0, max(count - 1, 0), count])).sorted().map { .torn(prefix: $0) }
    }

    @Test
    func sourceChangedAfterExportIsNotVerified() throws {
        let promote = InMemoryStagingFileSystem.FileOp.rename(Archive.staging, Archive.destination)
        let cases: [(start: InMemoryStagingFileSystem, path: String)] = [
            (Legacy.volume(), Legacy.draft),
            (Legacy.volume([Legacy.connections: Fixture.connectionsBytes]), Legacy.usbMap)
        ]
        for (start, path) in cases {
            let (log, shapes) = try cleanRun(start)
            let renamed = try #require(log.firstIndex { $0.operation == promote })
            let recheck = try #require(log.lastIndex { $0.operation == .status(path) })
            #expect(recheck > renamed, "\(path)")
            var store = start
            var script = InMemoryStagingFileSystem.Script()
            // A present file vanishes; an absent one appears (as a directory).
            if start.nodes[path] == nil { script.plant = [recheck: path] } else { script.remove = [recheck: path] }
            store.arm(script)
            #expect(try Archive.run(&store) == .refused(.sourcesChanged), "\(path)")
            #expect(store.shapes(at: Archive.destination) == shapes, "\(path)")
            #expect(store.shapes(at: Archive.staging).isEmpty, "\(path)")
        }
    }

    @Test
    func exportFaultCleansStagingAndKeepsOriginals() throws {
        let start = Legacy.volume()
        let (log, shapes) = try cleanRun(start)
        let firstWrite = try #require(log.firstIndex {
            if case .createFile = $0.operation { return true }
            return false
        })
        var store = start
        store.arm(.fault(.noSpace, at: firstWrite))
        let outcome = try Archive.run(&store)
        #expect(outcome == .refused(.staging(.ioFailed(step: .writeManifest, fault: .noSpace, cleanup: .removed))))
        #expect(store.shapes(at: Archive.destination).isEmpty)
        #expect(store.shapes(at: Archive.staging).isEmpty)
        #expect(Archive.untouched(store) == Archive.untouched(start))
        store.arm()
        #expect(Archive.archived(try Archive.run(&store)) != nil)
        #expect(store.shapes(at: Archive.destination) == shapes)
    }

    /// From a clean volume and from one holding a leftover staging tree, a crash before, after or tearing every
    /// operation leaves the originals exactly as they were, and the next run converges on the same archive.
    @Test
    func aCrashAtEveryOperationLeavesOriginalsAndConverges() throws {
        var leftover = Legacy.volume()
        leftover.seedDirectory(Archive.staging)
        leftover.seedFile(Archive.staging + "/manifest.json", Data("{".utf8))
        for start in [Legacy.volume(), leftover] {
            let (log, shapes) = try cleanRun(start)
            #expect(log.count > 30, "the log is too short to be a real sweep")
            var points = 0
            for index in log.indices {
                for crash in crashes(for: log[index]) {
                    points += 1
                    let label = "#\(index) \(crash) \(log[index].operation)"
                    var store = start
                    store.arm(.crash(crash, at: index))
                    let first = try Archive.run(&store)
                    #expect(Archive.untouched(store) == Archive.untouched(start), "\(label)")
                    let destination = store.shapes(at: Archive.destination)
                    #expect(destination.isEmpty || destination == shapes, "\(label)")
                    if Archive.archived(first) != nil { #expect(destination == shapes, "\(label)") }
                    store.arm()
                    let second = try Archive.run(&store)
                    switch second {
                    case .archived, .alreadyArchived: break
                    default: Issue.record("\(label): \(second)")
                    }
                    #expect(store.shapes(at: Archive.destination) == shapes, "\(label)")
                    #expect(store.shapes(at: Archive.staging).isEmpty, "\(label)")
                    #expect(Archive.untouched(store) == Archive.untouched(start), "\(label)")
                    store.arm()
                    let mark = store.log.count
                    guard case .alreadyArchived = try Archive.run(&store) else {
                        Issue.record("\(label): a third run was not already archived")
                        continue
                    }
                    #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating }, "\(label)")
                }
            }
            #expect(points > log.count * 2)
        }
    }

    // MARK: The re-read, the second source read and the refusals

    /// A volume already holding the archive, and the log (indexed from `arm`) of an unfaulted second run over it.
    private func secondRun() throws -> (start: ArchiveVolume, log: [ArchiveVolume.Entry]) {
        var start = Legacy.volume()
        _ = try #require(Archive.archived(try Archive.run(&start)))
        var probe = start
        probe.arm()
        let mark = probe.log.count
        let outcome = try Archive.run(&probe)
        guard case .alreadyArchived = outcome else {
            Issue.record("the second run was \(outcome)")
            return (start, [])
        }
        return (start, Array(probe.log.dropFirst(mark)))
    }

    private func reads(_ operation: ArchiveVolume.FileOp, under root: String) -> Bool {
        switch operation {
        case .status(let path), .list(let path, _), .read(let path, _, _): StagingPlan.isWithin(path, of: root)
        default: false
        }
    }

    /// A member planted in the fresh archive after the promote is found by the core's own re-read.
    @Test
    func freshArchiveIsReReadAfterPromote() throws {
        let start = Legacy.volume()
        let (log, _) = try cleanRun(start)
        let promote = ArchiveVolume.FileOp.rename(Archive.staging, Archive.destination)
        let renamed = try #require(log.firstIndex { $0.operation == promote })
        let reread = try #require(log.indices.first {
            $0 > renamed && reads(log[$0].operation, under: Archive.destination)
        })
        var store = start
        store.arm(ArchiveVolume.Script(plant: [reread: Archive.destination + "/extra"]))
        #expect(try Archive.run(&store) == .refused(.archiveDiffers))
        #expect(store.shapes(at: Archive.destination)["/extra"] != nil)
        #expect(Archive.untouched(store) == Archive.untouched(start))
    }

    /// A member silently corrupted in staging is caught by the export's verify step, before anything is promoted.
    @Test
    func exportVerifyRefusesACorruptedStagedMember() throws {
        let start = Legacy.volume()
        var store = start
        var script = ArchiveVolume.Script()
        script.silent = [Archive.staging + "/" + LegacyMigrationArchive.connectionsPath: .flipFirstByte]
        store.arm(script)
        #expect(try Archive.run(&store) == .refused(.staging(.verificationFailed(cleanup: .removed))))
        #expect(store.shapes(at: Archive.destination).isEmpty)
        #expect(store.shapes(at: Archive.staging).isEmpty)
        #expect(Archive.untouched(store) == Archive.untouched(start))
    }

    /// An existing, identical archive is not `alreadyArchived` when the archived draft vanishes while it is validated:
    /// the draft names no longer agree with the archive (P12 rule A; Home wiring and the USB map are not re-read).
    @Test
    func changedSourceOverAnExistingArchiveIsNotAlreadyArchived() throws {
        let (start, log) = try secondRun()
        let first = try #require(log.firstIndex { $0.operation == .status(Legacy.draft) })
        let recheck = try #require(log.lastIndex { $0.operation == .status(Legacy.draft) })
        #expect(recheck > first)
        var store = start
        store.arm(ArchiveVolume.Script(remove: [recheck: Legacy.draft]))
        let mark = store.log.count
        #expect(try Archive.run(&store) == .refused(.archiveDiffers))
        #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating })
        #expect(store.shapes(at: Archive.destination) == start.shapes(at: Archive.destination))
    }

    /// An IO fault while re-reading an existing archive is a staging failure, never a claim that it differs.
    @Test
    func existingArchiveReReadFaultIsStaging() throws {
        let (start, log) = try secondRun()
        let index = try #require(log.firstIndex {
            if case .read(let path, _, _) = $0.operation { return StagingPlan.isWithin(path, of: Archive.destination) }
            return false
        })
        var store = start
        store.arm(.fault(.ioError, at: index))
        let mark = store.log.count
        let outcome = try Archive.run(&store)
        guard case .refused(.staging(.ioFailed(step: _, fault: .ioError, cleanup: _))) = outcome else {
            Issue.record("unexpected \(outcome)")
            return
        }
        #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating })
        #expect(store.nodes == start.nodes)
    }

    @Test
    func recoveryFaultIsRefusedWithOriginalsKept() throws {
        var start = Legacy.volume()
        start.seedDirectory(Archive.staging)
        start.seedFile(Archive.staging + "/manifest.json", Data("{".utf8))
        let (log, _) = try cleanRun(start)
        let removal = try #require(log.firstIndex {
            if case .removeNode = $0.operation { return true }
            return false
        })
        var store = start
        store.arm(.fault(.denied, at: removal))
        let refusal = StagingRefusal.ioFailed(step: .cleanup, fault: .denied, cleanup: .notNeeded)
        #expect(try Archive.run(&store) == .refused(.recovery(refusal)))
        #expect(store.shapes(at: Archive.destination).isEmpty)
        #expect(Archive.untouched(store) == Archive.untouched(start))
    }

    /// Limits the reader accepts (every file is small) but the package refuses (too few entries): nothing is written.
    @Test
    func assemblyRefusalWritesNothing() throws {
        let limits = try ProjectPackageLimits(
            maxEntries: 3, maxDepth: 8, maxPathUTF8Bytes: 256, maxEntryBytes: 65_536, maxTotalBytes: 262_144
        )
        let policy = try ProjectPackageManifestPolicy(packageLimits: limits, maxManifestBytes: 65_536)
        let start = Legacy.volume()
        var store = start
        let outcome = LegacyMigrationArchive.archive(in: &store, projectID: Archive.projectID, policy: policy)
        guard case .refused(.assembly) = outcome else {
            Issue.record("unexpected \(outcome)")
            return
        }
        #expect(store.mutations.isEmpty)
        #expect(store.nodes == start.nodes)
    }

    /// The archive's own status of its destination (after recovery's) faults: refused before any write.
    @Test
    func destinationStatusFaultIsRefusedBeforeAnyWrite() throws {
        let start = Legacy.volume()
        let (log, _) = try cleanRun(start)
        let statuses = log.indices.filter { log[$0].operation == .status(Archive.destination) }
        #expect(statuses.count >= 2)
        var store = start
        store.arm(.fault(.ioError, at: try #require(statuses.dropFirst().first)))
        let refusal = StagingRefusal.ioFailed(step: .preflight, fault: .ioError, cleanup: .notNeeded)
        #expect(try Archive.run(&store) == .refused(.staging(refusal)))
        #expect(store.mutations.isEmpty)
        #expect(store.nodes == start.nodes)
    }
}

private typealias ArchiveVolume = InMemoryStagingFileSystem
