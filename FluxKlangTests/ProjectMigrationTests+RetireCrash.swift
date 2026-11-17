import Darwin
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `LegacyDraftRetirement` under a crash at every operation and on disk: the draft is always at exactly one of its
/// two names with its bytes and identity, and the next launch converges.
extension ProjectMigrationTests {
    /// Where the draft node is after a run: at exactly one of the two names, unchanged.
    private func draftIsAtOneName(
        _ store: InMemoryStagingFileSystem, _ draft: InMemoryStagingFileSystem.Node, _ label: String
    ) {
        let original = store.nodes[Legacy.draft]
        let retired = store.nodes[Retire.retired]
        #expect((original == nil) != (retired == nil), "\(label)")
        #expect((original ?? retired) == draft, "\(label)")
    }

    /// One launch: the archive, then the retirement with the receipt it returns.
    private func launch(
        _ store: inout InMemoryStagingFileSystem
    ) throws -> (archive: LegacyMigrationArchiveOutcome, retire: LegacyDraftRetirementOutcome?) {
        let archive = try Archive.run(&store)
        switch archive {
        case .archived(let receipt), .alreadyArchived(let receipt): return (archive, try Retire.run(receipt, &store))
        default: return (archive, nil)
        }
    }

    @Test
    func crashAtEveryRetireOperationConverges() throws {
        let (start, receipt) = try Retire.archived()
        let draft = try #require(start.nodes[Legacy.draft])
        let others = Retire.others(start.nodes)
        let log = try Retire.cleanLog(receipt, start)
        #expect(log.contains { $0.operation == .rename(Legacy.draft, Retire.retired) })
        var points = 0
        for index in log.indices {
            for crash in [InMemoryStagingFileSystem.Crash.before, .after] {
                points += 1
                let label = "#\(index) \(crash) \(log[index].operation)"
                var store = start
                store.arm(.crash(crash, at: index))
                let first = try Retire.run(receipt, &store)
                #expect(first != .retired, "\(label)")
                draftIsAtOneName(store, draft, label)
                #expect(Retire.others(store.nodes) == others, "\(label)")

                store.arm()
                let second = try launch(&store)
                #expect(Retire.alreadyArchived(second.archive) == receipt, "\(label)")
                #expect(second.retire == .retired || second.retire == .alreadyRetired, "\(label): \(second)")
                #expect(store.nodes[Legacy.draft] == nil, "\(label)")
                #expect(store.nodes[Retire.retired] == draft, "\(label)")
                #expect(Retire.others(store.nodes) == others, "\(label)")

                store.arm()
                let mark = store.log.count
                let third = try launch(&store)
                #expect(Retire.alreadyArchived(third.archive) == receipt, "\(label)")
                #expect(third.retire == .alreadyRetired, "\(label)")
                #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating }, "\(label)")
            }
        }
        #expect(points == log.count * 2)
    }

    /// A fault on the rename leaves the draft in place; one on the sync after it leaves the draft retired. Either way
    /// the next launch converges and nothing else changes.
    @Test
    func retireFaultsAreRefusedAndConverge() throws {
        let (start, receipt) = try Retire.archived()
        let draft = try #require(start.nodes[Legacy.draft])
        let log = try Retire.cleanLog(receipt, start)
        let rename = try #require(log.firstIndex { $0.operation == .rename(Legacy.draft, Retire.retired) })
        let sync = try #require(log.firstIndex { $0.operation == .syncDirectory("") })
        let cases: [(index: Int, holder: String)] = [(rename, Legacy.draft), (sync, Retire.retired)]
        for (index, holder) in cases {
            let step: StagingStep = index == rename ? .promote : .syncParent
            var store = start
            store.arm(.fault(.denied, at: index))
            let refusal = LegacyDraftRetirementRefusal.staging(
                .ioFailed(step: step, fault: .denied, cleanup: .notNeeded)
            )
            #expect(try Retire.run(receipt, &store) == .refused(refusal))
            #expect(store.nodes[holder] == draft)
            store.arm()
            #expect(try launch(&store).retire == (holder == Legacy.draft ? .retired : .alreadyRetired))
            #expect(store.nodes[Retire.retired] == draft)
        }
    }

    @Test
    func diskRetireRoundTrip() throws {
        let scratch = try Legacy.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = scratch.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try Legacy.write(Dictionary(uniqueKeysWithValues: ProjectMigrationSource.allCases.map {
            (Legacy.name($0), Fixture.valid($0))
        }), in: app)
        let originalURL = app.appendingPathComponent(Legacy.draft)
        let retiredURL = app.appendingPathComponent(Retire.retired)
        let before = try #require(Archive.inode(originalURL))
        let policy = try Archive.policy()

        let archived = LegacyMigrationArchive.archive(directory: app, projectID: Archive.projectID, policy: policy)
        let receipt = try #require(Archive.archived(archived))
        #expect(LegacyDraftRetirement.retire(receipt, directory: app, policy: policy) == .retired)
        let after = try #require(Archive.inode(retiredURL))
        #expect(after.st_ino == before.st_ino)
        #expect(after.st_dev == before.st_dev)
        #expect(Archive.inode(originalURL) == nil)
        #expect(Array(try Data(contentsOf: retiredURL)) == Array(Fixture.draftBytes))

        // The second launch is done and writes nothing.
        let again = LegacyMigrationArchive.archive(directory: app, projectID: Archive.projectID, policy: policy)
        #expect(Retire.alreadyArchived(again) == receipt)
        #expect(LegacyDraftRetirement.retire(receipt, directory: app, policy: policy) == .alreadyRetired)
        let listing = try FileManager.default.contentsOfDirectory(atPath: app.path).sorted()
        let expected = [Legacy.connections, Legacy.usbMap, Retire.retired, Archive.destination].sorted()
        #expect(listing == expected)

        // A new draft is left alone, and the real rename never replaces the retired file.
        try Retire.otherDraft.write(to: originalURL)
        #expect(LegacyDraftRetirement.retire(receipt, directory: app, policy: policy) == .alreadyRetired)
        let disk = try DiskStagingFileSystem(root: app, limits: policy.packageLimits)
        defer { disk.close() }
        #expect(throws: StagingIOFault.exists) { try disk.rename(from: Legacy.draft, to: Retire.retired) }
        #expect(Array(try Data(contentsOf: originalURL)) == Array(Retire.otherDraft))
        #expect(Array(try Data(contentsOf: retiredURL)) == Array(Fixture.draftBytes))
        #expect(Archive.inode(retiredURL)?.st_ino == before.st_ino)
    }
}
