import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectMigrationTests {
    enum Launch {
        static func run(_ store: inout InMemoryStagingFileSystem) throws -> LegacyMigrationLaunchOutcome {
            LegacyMigrationLaunch.observe(in: &store, policy: try Archive.policy())
        }

        static func observed(_ outcome: LegacyMigrationLaunchOutcome) -> LegacyMigrationObservation? {
            if case .observed(let observation) = outcome { return observation }
            return nil
        }

        static func log(_ start: InMemoryStagingFileSystem) throws -> [InMemoryStagingFileSystem.Entry] {
            var probe = start
            probe.arm()
            let mark = probe.log.count
            _ = try #require(observed(run(&probe)))
            return Array(probe.log.dropFirst(mark))
        }

        static func checkReview(_ observation: LegacyMigrationObservation) throws {
            let review = try #require(observation.review)
            #expect(review.draftID == UUID(uuidString: Fixture.draftID))
            #expect(review.createdAt == Date(timeIntervalSinceReferenceDate: 800_000_000.5))
            #expect(review.byteCount == Fixture.draftBytes.count)
            #expect(review.launch == observation.launch)
            #expect(review.status == Review.expectedStatus(observation.launch))
            #expect(review.source == "PendingStudioDraft")
            #expect(review.authority == "invalidated")
            #expect(review.reviewRequired && review.isRecognized && !review.canApply)
        }
    }

    @Test
    func launchObservationRetainsTheValidatedReportReceiptAndInertReview() throws {
        let (start, receipt) = try Retire.archived()
        var store = start
        store.seedDirectory(Archive.staging)
        store.seedFile(Archive.staging + "/leftover", Fixture.text("untouched"))
        store.seedFile(Legacy.connections, Fixture.text("changed home"))
        store.seedFile(Legacy.usbMap, Fixture.text("changed USB"))
        let before = store.nodes
        let mark = store.log.count
        let observation = try #require(Launch.observed(Launch.run(&store)))
        #expect(observation.report == receipt.report)
        #expect(observation.receipt == receipt)
        #expect(observation.launch == .pending)
        #expect(Legacy.adopted(observation.report, .pendingDraft) == Fixture.draftBytes)
        try Launch.checkReview(observation)
        Review.requireSendable(observation)
        #expect(try Archive.run(&store, projectID: ProjectID(validated: "prj.other")) == .alreadyArchived(receipt))
        #expect(store.nodes == before)
        #expect(Retire.writes(store, since: mark).isEmpty)
        let log = Array(store.log.dropFirst(mark))
        for entry in log {
            let operation = String(describing: entry.operation)
            #expect(!operation.contains(Legacy.connections) && !operation.contains(Legacy.usbMap))
            #expect(!operation.contains(Archive.staging))
        }
    }

    @Test
    func launchObservationRetiredNameWinsOverNewAndIdenticalOriginals() throws {
        let (start, receipt) = try Retire.archived()
        for bytes in [Retire.otherDraft, Fixture.draftBytes] {
            var store = start
            store.seedFile(Retire.retired, Fixture.draftBytes)
            store.seedFile(Legacy.draft, bytes)
            let before = store.nodes
            let mark = store.log.count
            let observation = try #require(Launch.observed(Launch.run(&store)))
            #expect(observation.launch == .retired)
            #expect(observation.receipt == receipt)
            try Launch.checkReview(observation)
            #expect(try Archive.run(&store) == .alreadyArchived(receipt))
            #expect(store.nodes == before)
            #expect(Retire.writes(store, since: mark).isEmpty)
        }
    }

    @Test
    func launchObservationConflictsKeepReviewButNeverMintAReceipt() throws {
        let (start, receipt) = try Retire.archived()
        let cases: [(LegacyDraftLaunchState, (inout InMemoryStagingFileSystem) -> Void)] = [
            (.draftChanged, { $0.seedFile(Legacy.draft, Retire.otherDraft) }),
            (.draftChanged, { $0.seedDirectory(Legacy.draft) }),
            (.draftGone, { $0.unseed(Legacy.draft) }),
            (.retiredNameOccupied, { $0.seedFile(Retire.retired, Retire.otherDraft) }),
            (.retiredNameOccupied, { $0.seedDirectory(Retire.retired) })
        ]
        for (state, edit) in cases {
            var store = start
            edit(&store)
            let before = store.nodes
            let mark = store.log.count
            let observation = try #require(Launch.observed(Launch.run(&store)))
            #expect(observation.report == receipt.report)
            #expect(observation.launch == state)
            #expect(observation.receipt == nil)
            try Launch.checkReview(observation)
            #expect(try Archive.run(&store) == .refused(.archiveDiffers))
            #expect(store.nodes == before)
            #expect(Retire.writes(store, since: mark).isEmpty)
        }
    }

    @Test
    func launchObservationDoesNotAdoptALateDraftIntoAHomeOnlyArchive() throws {
        let (start, receipt) = try Retire.archived([Legacy.connections: Fixture.connectionsBytes])
        var store = start
        store.seedFile(Legacy.draft, Fixture.draftBytes)
        store.seedFile(Legacy.usbMap, Fixture.usbMapBytes)
        let before = store.nodes
        let mark = store.log.count
        let observation = try #require(Launch.observed(Launch.run(&store)))
        #expect(observation.launch == .noDraftArchived)
        #expect(observation.report == receipt.report)
        #expect(observation.receipt == receipt)
        #expect(observation.receipt?.retirable == [])
        #expect(observation.review == nil)
        #expect(try Archive.run(&store) == .alreadyArchived(receipt))
        #expect(store.nodes == before)
        #expect(Retire.writes(store, since: mark).isEmpty)
        for entry in store.log.dropFirst(mark) {
            let operation = String(describing: entry.operation)
            #expect(!operation.contains(Legacy.draft) && !operation.contains(Retire.retired))
        }
    }

    @Test
    func launchObservationMissingArchiveNeverCreatesOrRecovers() throws {
        var store = Legacy.volume()
        store.seedDirectory(Archive.staging)
        store.seedFile(Archive.staging + "/leftover", Fixture.text("incomplete"))
        let before = store.nodes
        #expect(try Launch.run(&store) == .missingArchive)
        #expect(store.nodes == before)
        #expect(store.mutations.isEmpty)
        #expect(store.log.map(\.operation) == [.status(Archive.destination)])
        // The old entry point still recovers and creates a fresh archive.
        #expect(Archive.archived(try Archive.run(&store)) != nil)
        #expect(store.shapes(at: Archive.staging).isEmpty)
    }

    @Test
    func launchObservationRequiresTheCanonicalCommitRecordAndExactReconstruction() throws {
        var source = Legacy.volume()
        let policy = try Archive.policy()
        let report = LegacySourceReader.read(in: &source, limits: policy.packageLimits)
        let contents = try #require(try LegacyMigrationArchive.contents(
            report, projectID: Archive.projectID, policy: policy
        ))
        let members = [
            LegacyMigrationArchive.connectionsPath, LegacyMigrationArchive.usbMapPath, LegacyMigrationArchive.draftPath
        ].compactMap { path in contents.files.first { $0.path == path } }
        let edits: [(inout ProjectDocument) -> Void] = [
            { $0.extensions?["legacyMigration"] = nil },
            { $0.extensions?["provenance"] = .object(["authority": .string("granted")]) },
            { $0.name = "Not the recorded project" },
            { $0.extensions?["extra"] = .bool(true) },
            {
                guard case .object(var record)? = $0.extensions?["legacyMigration"] else { return }
                record["draft"] = .object(["id": .string(Fixture.draftID), "createdAt": .int(0)])
                $0.extensions?["legacyMigration"] = .object(record)
            },
            {
                guard case .object(var record)? = $0.extensions?["legacyMigration"],
                      case .object(var sources)? = record["sources"] else { return }
                sources["pendingDraft"] = Archive.state("missing")
                record["sources"] = .object(sources)
                $0.extensions?["legacyMigration"] = .object(record)
            }
        ]
        for edit in edits {
            var project = try Archive.project(contents)
            edit(&project)
            let invalid = try ProjectPackageContents.make(
                project: (LegacyMigrationArchive.projectPath, project), graphs: [], extraFiles: members, policy: policy
            )
            var store = Legacy.volume()
            store.seed(package: invalid, at: Archive.destination)
            let before = store.nodes
            // A well-formed package is not necessarily a migration commit.
            #expect(try Archive.read(&store) == invalid)
            #expect(try Launch.run(&store) == .refused(.invalidArchive))
            #expect(try Archive.run(&store) == .refused(.archiveDiffers))
            #expect(store.nodes == before)
            #expect(store.mutations.isEmpty)
        }
        var file = Legacy.volume()
        file.seedFile(Archive.destination, Fixture.text("not a package"))
        let before = file.nodes
        #expect(try Launch.run(&file) == .refused(.invalidArchive))
        #expect(try Archive.run(&file) == .refused(.archiveDiffers))
        #expect(file.nodes == before && file.mutations.isEmpty)
    }

    @Test
    func launchObservationReadFailuresStayTypedAndReadOnlyAtEveryPrimitive() throws {
        let start = try Retire.archived().store
        let log = try Launch.log(start)
        for index in log.indices {
            var store = start
            store.arm(.fault(.denied, at: index))
            let mark = store.log.count
            let result = try Launch.run(&store)
            guard case .refused(.readFailed(let refusal)) = result else {
                Issue.record("unexpected \(result) at \(index): \(log[index])")
                continue
            }
            #expect(store.nodes == start.nodes)
            #expect(Retire.writes(store, since: mark).isEmpty)
            var existing = start
            existing.arm(.fault(.denied, at: index))
            #expect(try Archive.run(&existing) == .refused(.staging(refusal)))
            #expect(existing.nodes == start.nodes)
            #expect(Retire.writes(existing, since: mark).isEmpty)
        }
        var oversized = start
        let path = Archive.destination + "/" + LegacyMigrationArchive.draftPath
        oversized.seedFile(path, Fixture.notUTF8(count: 65_537))
        let before = oversized.nodes
        let mark = oversized.log.count
        #expect(try Launch.run(&oversized) == .refused(.invalidArchive))
        #expect(try Archive.run(&oversized) == .refused(.archiveDiffers))
        #expect(oversized.nodes == before && Retire.writes(oversized, since: mark).isEmpty)
    }

    @Test
    func launchObservationRetainsArchiveAWhenArchiveBReplacesItAfterValidation() throws {
        let (start, receipt) = try Retire.archived()
        let log = try Launch.log(start)
        let boundary = try #require(log.firstIndex { $0.operation == .status(Legacy.draft) }) - 1
        #expect(log[boundary].operation == .status(""))
        let text = try #require(String(data: Retire.otherDraft, encoding: .utf8))
        for draft in [Retire.otherDraft, Fixture.text(text.replacingOccurrences(
            of: "800000000.5", with: "800000001.5"
        ))] {
            var other = try Retire.archived([
                Legacy.connections: Fixture.text(#"{"connections":{}}"#),
                Legacy.usbMap: Fixture.usbMapBytes, Legacy.draft: draft
            ]).store
            let archiveB = try Archive.read(&other)
            let replacements = [(Archive.destination + "/manifest.json", archiveB.manifestBytes)]
                + archiveB.files.map { (Archive.destination + "/" + $0.path, $0.bytes) }
            #expect(boundary + replacements.count <= log.count)
            var script = InMemoryStagingFileSystem.Script()
            for (offset, file) in replacements.enumerated() {
                script.plantFile[boundary + offset] = .init(path: file.0, bytes: file.1)
            }
            var store = start
            store.arm(script)
            let mark = store.log.count
            let observation = try #require(Launch.observed(Launch.run(&store)))
            #expect(observation.report == receipt.report)
            #expect(observation.receipt == receipt)
            #expect(observation.launch == .pending)
            try Launch.checkReview(observation)
            #expect(store.shapes(at: Archive.destination) == InMemoryStagingFileSystem.shapes(of: archiveB))
            #expect(store.nodes(outside: [Archive.destination]) == start.nodes(outside: [Archive.destination]))
            #expect(Retire.writes(store, since: mark).isEmpty)
            let reads = store.log.dropFirst(mark).filter {
                if case .read(let path, 0, _) = $0.operation { return path == replacements[0].0 }
                return false
            }
            #expect(reads.count == 1)
            // The same seam serves the old API, without a second archive-derived receipt.
            var existing = start
            existing.arm(script)
            #expect(try Archive.run(&existing) == .alreadyArchived(receipt))
            #expect(Retire.writes(existing, since: mark).isEmpty)
            #expect(existing.shapes(at: Archive.destination) == store.shapes(at: Archive.destination))
            store.arm()
            store.seedFile(Legacy.draft, draft)
            let later = try #require(Launch.observed(Launch.run(&store)))
            #expect(later.report != observation.report)
            #expect(later.review?.byteCount == draft.count)
            #expect(later.receipt?.report == later.report)
        }
    }
}
