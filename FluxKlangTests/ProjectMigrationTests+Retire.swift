import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Tests of `LegacyDraftRetirement` and of an existing archive as the commit record: the one rename, what is refused,
/// the receipt it needs, live changes after archiving and the launch-state table. Crashes and the disk round trip are
/// in `ProjectMigrationTests+RetireCrash.swift`.
extension ProjectMigrationTests {
    enum Retire {
        static let retired = "assistant-pending-studio-draft.retired-legacy1.json"
        /// A valid draft with other bytes: the fixture with one trailing space.
        static let otherDraft = Fixture.draftBytes + Fixture.text(" ")

        /// A volume holding `files` (the three fixtures by default) and their fresh archive, with its receipt.
        static func archived(
            _ files: [String: Data]? = nil
        ) throws -> (store: InMemoryStagingFileSystem, receipt: LegacyMigrationReceipt) {
            var store = Legacy.volume(files)
            let receipt = try #require(Archive.archived(try Archive.run(&store)))
            return (store, receipt)
        }

        static func run(
            _ receipt: LegacyMigrationReceipt, _ store: inout InMemoryStagingFileSystem
        ) throws -> LegacyDraftRetirementOutcome {
            LegacyDraftRetirement.retire(receipt, in: &store, policy: try Archive.policy())
        }

        /// The mutating operations logged since `mark`; the archive's own writes come before it.
        static func writes(_ store: InMemoryStagingFileSystem, since mark: Int) -> [InMemoryStagingFileSystem.Entry] {
            store.log.dropFirst(mark).filter(\.operation.isMutating)
        }

        /// The index of the draft's re-read: its last status after the retired name was read and before the rename.
        static func reread(in log: [InMemoryStagingFileSystem.Entry]) throws -> Int {
            let rename = try #require(log.firstIndex { $0.operation == .rename(Legacy.draft, retired) })
            let lookedAtRetired = try #require(log[..<rename].lastIndex { $0.operation == .status(retired) })
            return try #require(log[lookedAtRetired..<rename].lastIndex { $0.operation == .status(Legacy.draft) })
        }

        static func alreadyArchived(_ outcome: LegacyMigrationArchiveOutcome) -> LegacyMigrationReceipt? {
            if case .alreadyArchived(let receipt) = outcome { return receipt }
            return nil
        }

        /// The log, indexed from `arm`, of an unfaulted retirement over `start`.
        static func cleanLog(
            _ receipt: LegacyMigrationReceipt, _ start: InMemoryStagingFileSystem
        ) throws -> [InMemoryStagingFileSystem.Entry] {
            var probe = start
            probe.arm()
            let mark = probe.log.count
            #expect(try run(receipt, &probe) == .retired)
            return Array(probe.log.dropFirst(mark))
        }

        /// Every node but the two draft names: the archive, Home wiring, the USB map and any neighbour.
        static func others(
            _ nodes: [String: InMemoryStagingFileSystem.Node]
        ) -> [String: InMemoryStagingFileSystem.Node] {
            nodes.filter { $0.key != Legacy.draft && $0.key != retired }
        }
    }

    @Test
    func retireRenamesOnlyTheDraft() throws {
        let archived = try Retire.archived()
        var store = archived.store
        let receipt = archived.receipt
        store.seedFile("neighbour.json", Fixture.text("{}"))
        #expect(receipt.retirable == [.pendingDraft])
        let before = store.nodes
        let draft = try #require(before[Legacy.draft])
        store.arm()
        let mark = store.log.count
        #expect(try Retire.run(receipt, &store) == .retired)
        let mutations = store.log.dropFirst(mark).filter(\.operation.isMutating)
        #expect(mutations.map(\.operation) == [.rename(Legacy.draft, Retire.retired), .syncDirectory("")])
        #expect(mutations.allSatisfy { $0.outcome == .succeeded })
        #expect(store.nodes[Legacy.draft] == nil)
        #expect(store.nodes[Retire.retired] == draft)
        #expect(Retire.others(store.nodes) == Retire.others(before))
        for source in [ProjectMigrationSource.connections, .usbMap] {
            #expect(store.nodes[Legacy.name(source)] == before[Legacy.name(source)])
        }
    }

    @Test
    func retiredNameOccupiedIsRefused() throws {
        let (start, receipt) = try Retire.archived()
        for occupant in [Fixture.text("{}"), Retire.otherDraft] {
            var store = start
            store.seedFile(Retire.retired, occupant)
            let before = store.nodes
            let mark = store.log.count
            #expect(try Retire.run(receipt, &store) == .refused(.retiredNameOccupied))
            #expect(Retire.writes(store, since: mark).isEmpty)
            #expect(store.nodes == before)
        }
        var directory = start
        directory.seedDirectory(Retire.retired)
        let before = directory.nodes
        #expect(try Retire.run(receipt, &directory) == .refused(.retiredNameOccupied))
        #expect(directory.nodes == before)

        // The retired name appears after it was read, at the draft's re-read just before the rename: the rename
        // itself must not replace it.
        let reread = try Retire.reread(in: Retire.cleanLog(receipt, start))
        var race = start
        race.arm(InMemoryStagingFileSystem.Script(plant: [reread: Retire.retired]))
        #expect(try Retire.run(receipt, &race) == .refused(.retiredNameOccupied))
        #expect(race.nodes[Legacy.draft] == start.nodes[Legacy.draft])
        #expect(race.nodes[Retire.retired]?.kind == .directory)
    }

    @Test
    func draftChangedBeforeRenameIsRefused() throws {
        let (start, receipt) = try Retire.archived()
        var changed = start
        changed.unseed(Legacy.draft)
        changed.seedFile(Legacy.draft, Retire.otherDraft)
        let before = changed.nodes
        let mark = changed.log.count
        #expect(try Retire.run(receipt, &changed) == .refused(.draftChanged))
        #expect(Retire.writes(changed, since: mark).isEmpty)
        #expect(changed.nodes == before)

        // The draft is swapped after the first read: only the re-read just before the rename sees it.
        let reread = try Retire.reread(in: Retire.cleanLog(receipt, start))
        var swapped = start
        swapped.arm(InMemoryStagingFileSystem.Script(plant: [reread: Legacy.draft]))
        let swapMark = swapped.log.count
        #expect(try Retire.run(receipt, &swapped) == .refused(.draftChanged))
        #expect(Retire.writes(swapped, since: swapMark).isEmpty)
        #expect(swapped.nodes[Retire.retired] == nil)
        #expect(swapped.nodes[Legacy.draft]?.kind == .directory)
    }

    @Test
    func retireWithoutDraftReceiptWritesNothing() throws {
        let (_, partial) = try Retire.archived([
            Legacy.connections: Fixture.connectionsBytes, Legacy.usbMap: Fixture.usbMapBytes
        ])
        #expect(partial.retirable.isEmpty)
        // A receipt without a retirable draft does no IO at all, even over a volume whose draft could be retired.
        var store = try Retire.archived().store
        let before = store.nodes
        store.arm()
        let mark = store.log.count
        #expect(try Retire.run(partial, &store) == .nothingRetirable)
        #expect(store.log.count == mark)
        #expect(store.nodes == before)
    }

    // MARK: Rule A: the existing archive is the commit record

    @Test
    func homeEditAfterArchiveIsStillAlreadyArchived() throws {
        let (start, receipt) = try Retire.archived()
        let archive = start.shapes(at: Archive.destination)
        func replace(_ name: String, _ bytes: Data) -> (inout InMemoryStagingFileSystem) -> Void {
            { store in
                store.unseed(name)
                store.seedFile(name, bytes)
            }
        }
        let edits: [(String, (inout InMemoryStagingFileSystem) -> Void)] = [
            ("home edited", replace(Legacy.connections, Fixture.connectionsBytes + Fixture.text(" "))),
            ("home gone", { $0.unseed(Legacy.connections) }),
            ("usb edited", replace(Legacy.usbMap, Fixture.usbMapBytes + Fixture.text(" "))),
            ("usb gone", { $0.unseed(Legacy.usbMap) })
        ]
        for (label, edit) in edits {
            var store = start
            edit(&store)
            store.arm()
            let mark = store.log.count
            #expect(Retire.alreadyArchived(try Archive.run(&store)) == receipt, "\(label)")
            #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating }, "\(label)")
            #expect(store.shapes(at: Archive.destination) == archive, "\(label)")
            #expect(try Retire.run(receipt, &store) == .retired, "\(label)")
        }
        // An archive made without the USB map stays the record when the map appears later.
        let early = try Retire.archived([Legacy.connections: Fixture.connectionsBytes])
        var late = early.store
        late.seedFile(Legacy.usbMap, Fixture.usbMapBytes)
        #expect(Retire.alreadyArchived(try Archive.run(&late)) == early.receipt)
    }

    @Test
    func differentProjectIDIsStillAlreadyArchived() throws {
        let archived = try Retire.archived()
        var store = archived.store
        let archive = store.shapes(at: Archive.destination)
        store.arm()
        let mark = store.log.count
        let outcome = try Archive.run(&store, projectID: ProjectID(validated: "prj.other"))
        #expect(Retire.alreadyArchived(outcome) == archived.receipt)
        #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating })
        #expect(store.shapes(at: Archive.destination) == archive)
        #expect(try Archive.project(try Archive.read(&store)).id == Archive.projectID)
    }

    /// An existing archive's draft member must agree with the two draft names: another draft or none at the original
    /// name, or anything but the member at the retired name, makes it no longer the record of this volume. Nothing is
    /// written.
    @Test
    func draftNamesDisagreeingWithArchiveAreArchiveDiffers() throws {
        let archived = try Retire.archived()
        var retiredStart = archived.store
        #expect(try Retire.run(archived.receipt, &retiredStart) == .retired)
        func replace(_ name: String) -> (inout InMemoryStagingFileSystem) -> Void {
            { store in
                store.unseed(name)
                store.seedFile(name, Retire.otherDraft)
            }
        }
        func refused(
            _ label: String, _ start: InMemoryStagingFileSystem, _ edit: (inout InMemoryStagingFileSystem) -> Void
        ) throws {
            var store = start
            edit(&store)
            let before = store.nodes
            store.arm()
            let mark = store.log.count
            #expect(try Archive.run(&store) == .refused(.archiveDiffers), "\(label)")
            #expect(Retire.writes(store, since: mark).isEmpty, "\(label)")
            #expect(store.nodes == before, "\(label)")
        }
        try refused("original changed", archived.store, replace(Legacy.draft))
        try refused("original unusable", archived.store) { $0.unseed(Legacy.draft); $0.seedDirectory(Legacy.draft) }
        try refused("draft gone", archived.store) { $0.unseed(Legacy.draft) }
        try refused("retired occupied", archived.store, replace(Retire.retired))
        try refused("retired directory", archived.store) { $0.seedDirectory(Retire.retired) }
        try refused("retired replaced", retiredStart, replace(Retire.retired))
    }

    /// Validating an existing archive never reads Home wiring or the USB map, so either changing at any step of it
    /// still gives `.alreadyArchived`; a fresh archive's re-read would see the change and refuse.
    @Test
    func homeChangeDuringExistingArchiveValidationIsIgnored() throws {
        let (start, receipt) = try Retire.archived()
        var probe = start
        probe.arm()
        let mark = probe.log.count
        #expect(Retire.alreadyArchived(try Archive.run(&probe)) == receipt)
        let log = Array(probe.log.dropFirst(mark))
        for entry in log {
            let operation = String(describing: entry.operation)
            #expect(!operation.contains(Legacy.connections) && !operation.contains(Legacy.usbMap), "\(operation)")
        }
        for name in [Legacy.connections, Legacy.usbMap] {
            for index in log.indices {
                var store = start
                store.arm(InMemoryStagingFileSystem.Script(plant: [index: name]))
                #expect(Retire.alreadyArchived(try Archive.run(&store)) == receipt, "\(name) at \(index)")
                #expect(store.nodes[name]?.kind == .directory, "\(name) at \(index)")
            }
        }
    }

    // MARK: After retirement

    @Test
    func newDraftAfterRetireIsLeftAlone() throws {
        let archived = try Retire.archived()
        let receipt = archived.receipt
        var start = archived.store
        #expect(try Retire.run(receipt, &start) == .retired)
        let retired = try #require(start.nodes[Retire.retired])
        for bytes in [Retire.otherDraft, Fixture.draftBytes] {
            var store = start
            store.seedFile(Legacy.draft, bytes)
            let draft = try #require(store.nodes[Legacy.draft])
            store.arm()
            let mark = store.log.count
            #expect(Retire.alreadyArchived(try Archive.run(&store)) == receipt)
            #expect(try Retire.run(receipt, &store) == .alreadyRetired)
            #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating })
            #expect(store.nodes[Legacy.draft] == draft)
            #expect(store.nodes[Retire.retired] == retired)
        }
        // With no draft at the original name the next launch is simply done.
        var store = start
        store.arm()
        let mark = store.log.count
        #expect(Retire.alreadyArchived(try Archive.run(&store)) == receipt)
        #expect(try Retire.run(receipt, &store) == .alreadyRetired)
        #expect(store.log.dropFirst(mark).allSatisfy { !$0.operation.isMutating })
    }

    // MARK: Receipt and faults

    /// A receipt minted for draft A must not retire draft B, even when the archive and the live draft were both
    /// replaced by B's. The matching receipt still retires.
    @Test
    func staleReceiptDoesNotRetireAnotherDraft() throws {
        let (_, stale) = try Retire.archived()
        let other = try Retire.archived([
            Legacy.connections: Fixture.connectionsBytes, Legacy.usbMap: Fixture.usbMapBytes,
            Legacy.draft: Retire.otherDraft
        ])
        var store = other.store
        let before = store.nodes
        let mark = store.log.count
        #expect(stale != other.receipt)
        #expect(try Retire.run(stale, &store) == .refused(.receiptMismatch))
        #expect(Retire.writes(store, since: mark).isEmpty)
        #expect(store.nodes == before)
        #expect(store.nodes[Retire.retired] == nil)
        #expect(store.nodes[Legacy.draft] != nil)
        #expect(try Retire.run(other.receipt, &store) == .retired)
    }

    /// The first operation on the original draft name while running `run` over `start`: the one to fault.
    private func originalNameIndex(
        _ start: InMemoryStagingFileSystem, _ run: (inout InMemoryStagingFileSystem) throws -> Void
    ) throws -> Int {
        var probe = start
        probe.arm()
        let mark = probe.log.count
        try run(&probe)
        return try #require(probe.log.dropFirst(mark).firstIndex {
            switch $0.operation {
            case .status(let path), .read(let path, _, _): path == Legacy.draft
            default: false
            }
        }.map { $0 - mark })
    }

    /// The retired name decides: a read fault at the original name does not defeat a retired file that holds the
    /// archived draft, but it is still a fault while the retired name is free, and another occupant stays occupied.
    @Test
    func originalNameFaultYieldsToTheRetiredName() throws {
        let archived = try Retire.archived()
        let receipt = archived.receipt
        var retired = archived.store
        #expect(try Retire.run(receipt, &retired) == .retired)
        retired.seedFile(Legacy.draft, Retire.otherDraft)
        let policy = try Archive.policy()
        let refusal = LegacyDraftRetirementRefusal.staging(
            .ioFailed(step: .readSource, fault: .denied, cleanup: .notNeeded)
        )

        // (a) The archived draft is at the retired name: done, whatever the original name does.
        let retire = try originalNameIndex(retired) { _ = try Retire.run(receipt, &$0) }
        var store = retired
        store.arm(.fault(.denied, at: retire))
        #expect(try Retire.run(receipt, &store) == .alreadyRetired)
        let state = try originalNameIndex(retired) { _ = LegacyDraftRetirement.state(
            member: Fixture.draftBytes, in: &$0, policy: policy
        ) }
        store = retired
        store.arm(.fault(.denied, at: state))
        let launch = LegacyDraftRetirement.state(member: Fixture.draftBytes, in: &store, policy: policy)
        #expect(try launch.get() == .retired)
        let archive = try originalNameIndex(retired) { _ = try Archive.run(&$0) }
        store = retired
        store.arm(.fault(.denied, at: archive))
        #expect(Retire.alreadyArchived(try Archive.run(&store)) == receipt)

        // (b) The retired name is free: the fault is not swallowed.
        var free = archived.store
        let freeIndex = try originalNameIndex(free) { _ = try Retire.run(receipt, &$0) }
        free.arm(.fault(.denied, at: freeIndex))
        let freeBefore = free.nodes
        #expect(try Retire.run(receipt, &free) == .refused(refusal))
        #expect(free.nodes == freeBefore)

        // (c) The retired name holds other bytes: occupied, not a fault.
        var occupied = archived.store
        occupied.seedFile(Retire.retired, Retire.otherDraft)
        let occupiedIndex = try originalNameIndex(occupied) { _ = try Retire.run(receipt, &$0) }
        occupied.arm(.fault(.denied, at: occupiedIndex))
        #expect(try Retire.run(receipt, &occupied) == .refused(.retiredNameOccupied))
    }

    /// Every combination of the original and the retired name, with and without an archived draft.
    @Test
    func launchStateTable() {
        let member = Fixture.draftBytes
        let nodes: [LegacyDraftNode] = [.absent, .file(member), .file(Retire.otherDraft), .unusable]
        // Rows: the original name; columns: the retired name; both in the order of `nodes`.
        let table: [[LegacyDraftLaunchState]] = [
            [.draftGone, .retired, .retiredNameOccupied, .retiredNameOccupied],
            [.pending, .retired, .retiredNameOccupied, .retiredNameOccupied],
            [.draftChanged, .retired, .retiredNameOccupied, .retiredNameOccupied],
            [.draftChanged, .retired, .retiredNameOccupied, .retiredNameOccupied]
        ]
        for (row, original) in nodes.enumerated() {
            for (column, retired) in nodes.enumerated() {
                let none = LegacyDraftRetirement.launchState(member: nil, original: original, retired: retired)
                #expect(none == .noDraftArchived, "\(original) \(retired)")
                let state = LegacyDraftRetirement.launchState(member: member, original: original, retired: retired)
                #expect(state == table[row][column], "\(original) \(retired)")
            }
        }
    }
}
