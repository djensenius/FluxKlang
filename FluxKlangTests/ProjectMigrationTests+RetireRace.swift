import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `LegacyDraftRetirement` when a draft writer breaks the precondition and replaces the draft between the re-read and
/// the rename: the rename moves the writer's file, the read-back sees another file and the retirement renames it back
/// without replacing. Nothing is ever deleted.
extension ProjectMigrationTests {
    /// The archived volume with its receipt, and the indexes from `arm` of the rename and of the read-back after it.
    private struct Race {
        /// What a concurrent save puts at the original name just before the rename.
        static let replacement = InMemoryStagingFileSystem.PlantedFile(path: Legacy.draft, bytes: Retire.otherDraft)
        /// A still newer draft from a second save.
        static let newer = Fixture.draftBytes + Fixture.text("  ")
        /// Every write of a rolled-back retirement, in order.
        static let rollback: [InMemoryStagingFileSystem.FileOp] = [
            .rename(Legacy.draft, Retire.retired), .syncDirectory(""), .rename(Retire.retired, Legacy.draft),
            .syncDirectory("")
        ]

        let start: InMemoryStagingFileSystem
        let receipt: LegacyMigrationReceipt
        let rename: Int
        let readBack: Int
        /// The operations of a run with the draft replaced at the rename.
        let raced: [InMemoryStagingFileSystem.FileOp]

        /// Replaces the draft at the rename.
        var swap: InMemoryStagingFileSystem.Script { .init(plantFile: [rename: Self.replacement]) }

        init() throws {
            let (start, receipt) = try Retire.archived()
            let clean = try Retire.cleanLog(receipt, start)
            let rename = try #require(clean.firstIndex { $0.operation == .rename(Legacy.draft, Retire.retired) })
            var probe = start
            probe.arm(InMemoryStagingFileSystem.Script(plantFile: [rename: Self.replacement]))
            let mark = probe.log.count
            _ = try Retire.run(receipt, &probe)
            let raced = probe.log.dropFirst(mark).map(\.operation)
            try #require(raced.count > rename)
            self.start = start
            self.receipt = receipt
            self.rename = rename
            self.raced = raced
            readBack = try #require(raced[rename...].firstIndex(of: .status(Retire.retired)))
        }

        /// The index of the rename back in a run with the draft replaced at the rename.
        func back() throws -> Int {
            try #require(raced.firstIndex(of: .rename(Retire.retired, Legacy.draft)))
        }

        /// Runs the retirement with `file` planted at the rename and checks it rolled back: the writes are exactly the
        /// rollback, `file` is at the original name and the retired name is free. Returns the store and the original
        /// draft's node.
        func expectRestored(
            _ file: InMemoryStagingFileSystem.PlantedFile
        ) throws -> (store: InMemoryStagingFileSystem, draft: InMemoryStagingFileSystem.Node) {
            let draft = try #require(start.nodes[Legacy.draft])
            var store = start
            store.arm(.init(plantFile: [rename: file]))
            let mark = store.log.count
            #expect(try Retire.run(receipt, &store) == .refused(.draftReplacedDuringRetirement(.restored)))
            let writes = Retire.writes(store, since: mark)
            #expect(writes.map(\.operation) == Self.rollback)
            #expect(writes.allSatisfy { $0.outcome == .succeeded })
            #expect(store.nodes[Legacy.draft]?.bytes == file.bytes)
            #expect(store.nodes[Retire.retired] == nil)
            #expect(Retire.others(store.nodes) == Retire.others(start.nodes))
            return (store, draft)
        }
    }

    /// A save replaces the draft at the rename: the rename moves the save's file, the read-back sees another file and
    /// the retirement renames it back, so the save's draft is at the name the store loads and the retired name is free.
    @Test
    func draftReplacedAtTheRenameIsRenamedBack() throws {
        let race = try Race()
        let result = try race.expectRestored(Race.replacement)
        var store = result.store
        let restored = try #require(store.nodes[Legacy.draft])
        #expect(restored.identity != result.draft.identity)

        // The next launch: the archive holds the older draft and the original name the save's newer one, so the
        // archive no longer describes this volume and the receipt cannot retire a draft the archive does not hold.
        store.arm()
        let rerun = store.log.count
        #expect(try Archive.run(&store) == .refused(.archiveDiffers))
        #expect(try Retire.run(race.receipt, &store) == .refused(.draftChanged))
        #expect(Retire.writes(store, since: rerun).isEmpty)
        #expect(store.nodes[Legacy.draft] == restored)
        #expect(store.nodes[Retire.retired] == nil)
    }

    /// A save writes the same bytes as a new file at the rename: only the identity tells the read-back it is another
    /// file, and it is renamed back. Its bytes are the archived draft's, so the next run retires it.
    @Test
    func sameBytesSavedAtTheRenameIsRenamedBack() throws {
        let race = try Race()
        let file = InMemoryStagingFileSystem.PlantedFile(path: Legacy.draft, bytes: Fixture.draftBytes)
        let result = try race.expectRestored(file)
        var store = result.store
        let saved = try #require(store.nodes[Legacy.draft])
        #expect(saved.identity != result.draft.identity)

        store.arm()
        #expect(try Retire.run(race.receipt, &store) == .retired)
        #expect(store.nodes[Legacy.draft] == nil)
        #expect(store.nodes[Retire.retired] == saved)
    }

    /// A writer rewrites the draft in place at the rename: only the bytes tell the read-back it is another file, and it
    /// is renamed back.
    @Test
    func draftRewrittenInPlaceAtTheRenameIsRenamedBack() throws {
        let race = try Race()
        let draft = try #require(race.start.nodes[Legacy.draft])
        let file = InMemoryStagingFileSystem.PlantedFile(
            path: Legacy.draft, bytes: Retire.otherDraft, identity: draft.identity
        )
        let (store, _) = try race.expectRestored(file)
        #expect(store.nodes[Legacy.draft]?.identity == draft.identity)
        #expect(store.nodes[Legacy.draft]?.volume == draft.volume)
    }

    /// A second save takes the original name before the rename back, which does not replace it: the moved draft stays
    /// at the retired name. Both are kept; the retired name now holds a draft the archive does not hold, which every
    /// later launch reports as occupied without writing.
    @Test
    func newerDraftAtTheOriginalNameKeepsBoth() throws {
        let race = try Race()
        let back = try race.back()
        var script = race.swap
        script.plantFile[back] = InMemoryStagingFileSystem.PlantedFile(path: Legacy.draft, bytes: Race.newer)
        var store = race.start
        store.arm(script)
        let mark = store.log.count
        let outcome = try Retire.run(race.receipt, &store)
        #expect(outcome == .refused(.draftReplacedDuringRetirement(.originalNameOccupied)))
        let writes = Retire.writes(store, since: mark)
        #expect(writes.map(\.operation) == Array(Race.rollback.prefix(3)))
        #expect(writes.last?.outcome == .fault(.exists))
        #expect(store.nodes[Legacy.draft]?.bytes == Race.newer)
        #expect(store.nodes[Retire.retired]?.bytes == Retire.otherDraft)
        #expect(Retire.others(store.nodes) == Retire.others(race.start.nodes))

        let after = store.nodes
        store.arm()
        let rerun = store.log.count
        let state = LegacyDraftRetirement.state(member: Fixture.draftBytes, in: &store, policy: try Archive.policy())
        #expect(try state.get() == .retiredNameOccupied)
        #expect(try Archive.run(&store) == .refused(.archiveDiffers))
        #expect(try Retire.run(race.receipt, &store) == .refused(.retiredNameOccupied))
        #expect(Retire.writes(store, since: rerun).isEmpty)
        #expect(store.nodes == after)
    }

    /// The rename back or the sync after it fails or crashes: `.restoreFailed` names the step, the moved draft is at
    /// one of the two names and the archive still holds the archived draft.
    @Test
    func failedRenameBackIsRestoreFailed() throws {
        let race = try Race()
        let back = try race.back()
        func raced(_ script: InMemoryStagingFileSystem.Script) -> InMemoryStagingFileSystem.Script {
            var raced = script
            raced.plantFile = race.swap.plantFile
            return raced
        }
        let cases: [(script: InMemoryStagingFileSystem.Script, step: StagingStep)] = [
            (raced(.fault(.denied, at: back)), .restorePrevious),
            (raced(.crash(.before, at: back)), .restorePrevious),
            (raced(.crash(.after, at: back)), .restorePrevious),
            (raced(.fault(.ioError, at: back + 1)), .syncParent)
        ]
        for (index, (script, step)) in cases.enumerated() {
            let label = "case \(index)"
            var store = race.start
            store.arm(script)
            let mark = store.log.count
            let outcome = try Retire.run(race.receipt, &store)
            #expect(outcome == .refused(.draftReplacedDuringRetirement(.restoreFailed(step))), "\(label)")
            let writes = Retire.writes(store, since: mark).map(\.operation)
            #expect(writes == Array(Race.rollback.prefix(step == .syncParent ? 4 : 3)), "\(label)")
            let moved = [store.nodes[Legacy.draft], store.nodes[Retire.retired]].compactMap { $0 }
            #expect(moved.map(\.bytes) == [Retire.otherDraft], "\(label)")
            #expect(Retire.others(store.nodes) == Retire.others(race.start.nodes), "\(label)")
            store.arm()
            let archived = Archive.file(LegacyMigrationArchive.draftPath, in: try Archive.read(&store))
            #expect(archived == Fixture.draftBytes, "\(label)")
        }
    }

    /// A read-back that fails leaves the state unknown: `verificationFailed`, and nothing is renamed back, with or
    /// without a replaced draft.
    @Test
    func readBackFaultWritesNothingMore() throws {
        let race = try Race()
        let refusal = LegacyDraftRetirementRefusal.staging(.verificationFailed(cleanup: .notNeeded))
        for swapped in [false, true] {
            var script = InMemoryStagingFileSystem.Script.fault(.ioError, at: race.readBack)
            if swapped { script.plantFile = race.swap.plantFile }
            var store = race.start
            store.arm(script)
            let mark = store.log.count
            #expect(try Retire.run(race.receipt, &store) == .refused(refusal), "\(swapped)")
            let writes = Retire.writes(store, since: mark).map(\.operation)
            #expect(writes == Array(Race.rollback.prefix(2)), "\(swapped)")
            #expect(store.nodes[Legacy.draft] == nil, "\(swapped)")
            let moved = swapped ? Retire.otherDraft : Fixture.draftBytes
            #expect(store.nodes[Retire.retired]?.bytes == moved, "\(swapped)")
        }
    }
}
