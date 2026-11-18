import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.serialized, .productionAccessAudit)
@MainActor
struct PendingStudioPatchPersistenceTests {
    @Test func roundTripAndMalformedReads() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let draft = fixture.draft()
            #expect(await fixture.store.load() == .absent)
            #expect(await fixture.store.save(nil) == .alreadyAbsent)
            #expect(await fixture.store.save(draft) == .writeCompleted)
            #expect(await fixture.store.load() == .loaded(draft))
            for bytes in [Data("{".utf8), Data("{\"unsupported\":true}".utf8)] {
                try bytes.write(to: fixture.file)
                #expect(await fixture.store.load() == .malformedOrUnsupported)
                #expect(try Data(contentsOf: fixture.file) == bytes)
            }
            #expect(await fixture.store.save(nil) == .deleteCompleted)
            #expect(await fixture.store.save(nil) == .alreadyAbsent)
            #expect(await fixture.store.load() == .absent)
        }
    }

    @Test func obstructedParentIsNotAbsenceOrCompletion() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let blocker = fixture.file.deletingLastPathComponent()
            let bytes = Data("owned blocker".utf8)
            try bytes.write(to: blocker)
            #expect(await fixture.store.load() == .readFailed(.notDirectory))
            let write = await fixture.store.save(fixture.draft())
            guard case .directoryPreparationFailed = write else {
                Issue.record("Expected directory preparation failure, got \(write)")
                return
            }
            #expect(!write.completed)
            #expect(await fixture.store.save(nil) == .mutationFailedEffectUnconfirmed(.notDirectory))
            #expect(try Data(contentsOf: blocker) == bytes)
        }
    }

    @Test func directoryWriteFailurePreservesSentinel() async throws {
        try await PendingPersistenceFixture.run { fixture in
            try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: true)
            let sentinel = fixture.file.appendingPathComponent("sentinel")
            let bytes = Data("owned sentinel".utf8)
            try bytes.write(to: sentinel)
            let outcome = await fixture.store.save(fixture.draft())
            guard case .mutationFailedEffectUnconfirmed = outcome else {
                Issue.record("Expected unconfirmed mutation failure, got \(outcome)")
                return
            }
            #expect(!outcome.completed)
            #expect(try Data(contentsOf: sentinel) == bytes)
            let deletion = await fixture.store.save(nil)
            #expect(!deletion.completed)
            #expect(try Data(contentsOf: sentinel) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.file.path) == ["sentinel"])
            try FileManager.default.removeItem(at: sentinel)
            #expect(!(await fixture.store.save(nil)).completed)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.file.path).isEmpty)
        }
    }

    @Test func encodingFailsBeforeDirectoryPreparation() async throws {
        try await PendingPersistenceFixture.run { fixture in
            var draft = fixture.draft()
            #expect(await fixture.store.save(draft) == .writeCompleted)
            let bytes = try Data(contentsOf: fixture.file)
            draft.fragment.nodes[0].node.position.x = .infinity
            #expect(await fixture.store.save(draft) == .encodingFailed)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            let missing = fixture.root.appendingPathComponent("missing/nested/draft.json")
            let store = PendingStudioPatchStore(fileURL: missing, directory: fixture.root)
            #expect(await store.save(draft) == .encodingFailed)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("missing").path))
        }
    }

    @Test func syntheticClassifierIsBoundedAndTextFree() {
        // Synthetic NSError cases, not observed permission or disk-full filesystem failures.
        let cases: [(NSError, PendingStudioPatchIOError)] = [
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)), .absent),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)), .failure(.notDirectory)),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR)), .failure(.isDirectory)),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), .failure(.permissionDenied)),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), .failure(.permissionDenied)),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .failure(.outOfSpace)),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError), .absent),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), .absent),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), .failure(.permissionDenied)),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), .failure(.permissionDenied)),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .failure(.outOfSpace)),
            (NSError(domain: NSCocoaErrorDomain, code: Int.max), .failure(.other)),
            (NSError(domain: "caller-secret", code: Int(ENOENT)), .failure(.other)),
            (NSError(domain: NSPOSIXErrorDomain, code: Int.max), .failure(.other))
        ]
        for (synthetic, expected) in cases {
            let error = NSError(domain: synthetic.domain, code: synthetic.code, userInfo: [
                NSFilePathErrorKey: "/caller-secret", NSLocalizedDescriptionKey: "payload-secret"
            ])
            let classified = PendingStudioPatchIOError.classify(error)
            #expect(classified == expected)
            #expect(!String(describing: classified).contains("secret"))
        }
        var nested = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        for depth in 1...4 {
            nested = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                             userInfo: [NSUnderlyingErrorKey: nested])
            #expect(PendingStudioPatchIOError.classify(nested) ==
                (depth < 4 ? .failure(.notDirectory) : .failure(.other)))
        }
    }

    @Test func buildRevalidateLoadAndDiscardRecordExactSnapshots() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            let build = try fixture.attempt()
            #expect(build.observation == .mutation(snapshot: built, outcome: .writeCompleted))
            _ = await fixture.owner.perform(.validatePendingStudioDraft, context: fixture.context)
            let refreshed = try #require(fixture.owner.pendingStudioDraft)
            let validation = try fixture.attempt()
            #expect(validation !== build)
            #expect(validation.observation == .mutation(snapshot: refreshed, outcome: .writeCompleted))
            await fixture.owner.load()
            #expect(fixture.owner.pendingStudioDraft == refreshed)
            #expect(try fixture.attempt().observation == .load(.loaded(refreshed)))
            _ = await fixture.owner.perform(.openReview, context: fixture.context)
            let gate = await fixture.forwarding.hold(.beforeSave(3))
            let discard = fixture.start { await fixture.owner.discardPendingStudioDraft() }
            try #require(await gate.waitForEntry())
            let deletion = try fixture.attempt()
            #expect(deletion.observation == .mutation(snapshot: nil, outcome: nil))
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(fixture.owner.navigationTarget == nil)
            await gate.release()
            await discard.value
            #expect(deletion.observation == .mutation(snapshot: nil, outcome: .deleteCompleted))
            #expect(await fixture.forwarding.snapshots == [built, refreshed, nil])
            #expect(build.observation == .mutation(snapshot: built, outcome: .writeCompleted))
        }
    }

    @Test func failedDiscardStillClearsMemoryAndNavigation() async throws {
        try await PendingPersistenceFixture.run { fixture in
            _ = try await fixture.build()
            _ = await fixture.owner.perform(.openReview, context: fixture.context)
            let parent = fixture.file.deletingLastPathComponent()
            try FileManager.default.removeItem(at: parent)
            let bytes = Data("owned blocker".utf8)
            try bytes.write(to: parent)
            await fixture.owner.discardPendingStudioDraft()
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(fixture.owner.navigationTarget == nil)
            #expect(try fixture.attempt().observation == .mutation(
                snapshot: nil, outcome: .mutationFailedEffectUnconfirmed(.notDirectory)))
            #expect(await fixture.forwarding.snapshots.count == 2)
            #expect(try Data(contentsOf: parent) == bytes)
        }
    }

    @Test func failedSaveStillReportsInMemoryStaging() async throws {
        try await PendingPersistenceFixture.run { fixture in
            var draft = fixture.draft()
            draft.fragment.nodes[0].node.position.x = .infinity
            #expect(await fixture.commit(draft))
            #expect(fixture.owner.pendingStudioDraft == draft)
            let attempt = try fixture.attempt()
            #expect(attempt.observation == .mutation(snapshot: draft, outcome: .encodingFailed))
            #expect(await fixture.forwarding.snapshots == [draft])
            #expect(await fixture.store.load() == .absent)
        }
    }

    @Test func failureStopsCatchUpDespiteChangedPending() async throws {
        try await PendingPersistenceFixture.run { fixture in
            var invalid = fixture.draft()
            invalid.fragment.nodes[0].node.position.x = .infinity
            let submitted = invalid
            let gate = await fixture.forwarding.hold(.afterSave(1))
            let first = fixture.start { await fixture.commit(submitted) }
            try #require(await gate.waitForEntry())
            let older = try fixture.attempt()
            #expect(older.observation == .mutation(snapshot: submitted, outcome: nil))
            let newerDraft = fixture.draft(1)
            #expect(await fixture.commit(newerDraft))
            let newer = try fixture.attempt()
            #expect(newer !== older)
            await gate.release()
            #expect(await first.value == false)
            #expect(older.observation == .mutation(snapshot: submitted, outcome: .encodingFailed))
            #expect(fixture.owner.latestStorageAttempt === newer)
            #expect(newer.observation == .mutation(snapshot: newerDraft, outcome: .writeCompleted))
            #expect(await fixture.forwarding.snapshots == [submitted, newerDraft])
        }
    }
}

extension PendingStudioPatchPersistenceTests {
    @Test(arguments: ["file", "directory", "dangling"])
    func deletionUnlinksFinalSymlinkOnly(kind: String) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let manager = FileManager.default
            let target = fixture.root.appendingPathComponent("target")
            let bytes = Data("owned target".utf8)
            if kind == "directory" {
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
                try bytes.write(to: target.appendingPathComponent("sentinel"))
            } else if kind == "file" {
                try bytes.write(to: target)
            }
            let parent = fixture.file.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: false)
            try manager.createSymbolicLink(at: fixture.file, withDestinationURL: target)
            try #require(try manager.destinationOfSymbolicLink(atPath: fixture.file.path) == target.path)
            #expect(!fixture.file.path.hasSuffix("/"))
            #expect(await fixture.store.save(nil) == .deleteCompleted)
            #expect(try manager.contentsOfDirectory(atPath: parent.path).isEmpty)
            if kind == "directory" {
                #expect(try manager.contentsOfDirectory(atPath: target.path) == ["sentinel"])
                #expect(try Data(contentsOf: target.appendingPathComponent("sentinel")) == bytes)
            } else if kind == "file" {
                #expect(try Data(contentsOf: target) == bytes)
            } else {
                #expect(try manager.contentsOfDirectory(atPath: fixture.root.path) == ["pending"])
            }
        }
    }

    @Test func deletionPreservesOtherHardLink() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let other = fixture.root.appendingPathComponent("other")
            let bytes = Data("owned hard link".utf8)
            try bytes.write(to: other)
            let parent = fixture.file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try FileManager.default.linkItem(at: other, to: fixture.file)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(await fixture.store.save(nil) == .deleteCompleted)
            #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
            #expect(try Data(contentsOf: other) == bytes)
        }
    }

    @Test(arguments: [false, true])
    func deletionRejectsMalformedURLWithoutTouchingPrefix(containsNUL: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let sentinel = fixture.root.appendingPathComponent("sentinel")
            let bytes = Data("owned URL prefix".utf8)
            try bytes.write(to: sentinel)
            let expectedPath = sentinel.path + (containsNUL ? "\0suffix" : "")
            var components = try #require(URLComponents(url: sentinel, resolvingAgainstBaseURL: false))
            components.scheme = containsNUL ? "file" : "https"
            components.host = containsNUL ? "" : "invalid.example"
            components.path = expectedPath
            let url = try #require(components.url)
            let decodesNUL = url.path.contains("\0")
            let representation = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } }
            try #require(url.isFileURL == containsNUL)
            if containsNUL {
                #expect(components.percentEncodedPath.hasSuffix("%00suffix"))
                if !decodesNUL {
                    #expect(representation == sentinel.path + "%00suffix")
                }
            } else {
                try #require(url.path == expectedPath)
            }
            let store = PendingStudioPatchStore(fileURL: url, directory: fixture.root)
            let outcome = await store.save(nil)
            #expect(outcome == (containsNUL && !decodesNUL ? .alreadyAbsent : .mutationFailedEffectUnconfirmed(.other)))
            #expect(try Data(contentsOf: sentinel) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["sentinel"])
        }
    }

    @Test func failedDiscardResultCannotCatchUpOrPromoteOverNewerCommit() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let built = try await fixture.build()
            _ = await fixture.owner.perform(.openReview, context: fixture.context)
            #expect(fixture.owner.navigationTarget == .reviewPendingDraft)
            try FileManager.default.removeItem(at: fixture.file)
            try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
            let sentinel = fixture.file.appendingPathComponent("sentinel")
            let bytes = Data("owned delayed discard".utf8)
            try bytes.write(to: sentinel)
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let discard = fixture.start { await fixture.owner.discardPendingStudioDraft() }
            try #require(await gate.waitForEntry())
            let older = try fixture.attempt()
            #expect(older.observation == .mutation(snapshot: nil, outcome: nil))
            #expect(await fixture.forwarding.snapshots == [built, nil])
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(fixture.owner.navigationTarget == nil)
            #expect(try Data(contentsOf: sentinel) == bytes)
            let moved = fixture.root.appendingPathComponent("preserved")
            try FileManager.default.moveItem(at: fixture.file, to: moved)
            let newerDraft = fixture.draft(1)
            try #require(newerDraft != built)
            #expect(await fixture.commit(newerDraft))
            let newer = try fixture.attempt()
            #expect(newer !== older)
            #expect(newer.observation == .mutation(snapshot: newerDraft, outcome: .writeCompleted))
            await gate.release()
            await discard.value
            guard case .mutation(nil, .some(.mutationFailedEffectUnconfirmed)) = older.observation else {
                Issue.record("Expected historical nil-snapshot deletion failure, got \(older.observation)")
                return
            }
            #expect(fixture.owner.latestStorageAttempt === newer)
            #expect(newer.observation == .mutation(snapshot: newerDraft, outcome: .writeCompleted))
            #expect(await fixture.forwarding.snapshots == [built, nil, newerDraft])
            #expect(fixture.owner.pendingStudioDraft == newerDraft)
            #expect(await fixture.store.load() == .loaded(newerDraft))
            #expect(try Data(contentsOf: moved.appendingPathComponent("sentinel")) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["sentinel"])
        }
    }

    @Test(arguments: [false, true])
    func failedReloadRetainsCompletionStateAndCancellationEligibility(readFailure: Bool) async throws {
        try await PendingPersistenceFixture.run { fixture in
            let settled = try await fixture.build()
            try FileManager.default.removeItem(at: fixture.file)
            if readFailure {
                try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
            } else {
                try Data("{".utf8).write(to: fixture.file)
            }
            let readGate = await fixture.forwarding.hold(.afterLoad(1))
            let reload = fixture.start { await fixture.owner.load() }
            try #require(await readGate.waitForEntry())
            let read = try fixture.attempt()
            #expect(read.observation == .load(nil))
            // The real failed read is already held. Change state before it returns.
            try FileManager.default.removeItem(at: fixture.file)
            let draft = fixture.draft(1)
            let saveGate = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commit(draft) }
            try #require(await saveGate.waitForEntry())
            let mutation = try fixture.attempt()
            #expect(fixture.owner.pendingStudioDraft == draft)
            #expect(draft != settled)
            await readGate.release()
            await reload.value
            #expect(read.observation == .load(readFailure ? .readFailed(.isDirectory) : .malformedOrUnsupported))
            #expect(fixture.owner.pendingStudioDraft == draft)
            #expect(fixture.owner.latestStorageAttempt === mutation)
            let restoreGate = await fixture.forwarding.hold(.afterSave(3))
            commit.cancel()
            await saveGate.release()
            try #require(await restoreGate.waitForEntry())
            let restoration = try fixture.attempt()
            #expect(mutation.observation == .mutation(snapshot: draft, outcome: .writeCompleted))
            #expect(restoration !== mutation && restoration !== read)
            #expect(restoration.observation == .mutation(snapshot: settled, outcome: nil))
            #expect(fixture.owner.pendingStudioDraft == settled)
            await restoreGate.release()
            #expect(await commit.value == false)
            #expect(restoration.observation == .mutation(snapshot: settled, outcome: .writeCompleted))
            // A second cancellation uses the retained settled state, not the failed reload's pending draft.
            let nextGate = await fixture.forwarding.hold(.afterSave(4))
            let next = fixture.start { await fixture.commit(draft) }
            try #require(await nextGate.waitForEntry())
            next.cancel()
            await nextGate.release()
            #expect(await next.value == false)
            #expect(fixture.owner.pendingStudioDraft == settled)
            #expect(await fixture.forwarding.snapshots == [settled, draft, settled, draft, settled])
        }
    }

    @Test func successfulAbsenceResetsSettledState() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let draft = try await fixture.build()
            #expect(await fixture.store.save(nil) == .deleteCompleted)
            await fixture.owner.load()
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(try fixture.attempt().observation == .load(.absent))
            let gate = await fixture.forwarding.hold(.afterSave(2))
            let commit = fixture.start { await fixture.commit(draft) }
            try #require(await gate.waitForEntry())
            commit.cancel()
            await gate.release()
            #expect(await commit.value == false)
            #expect(fixture.owner.pendingStudioDraft == nil)
            #expect(try fixture.attempt().observation == .mutation(snapshot: nil, outcome: .deleteCompleted))
            #expect(await fixture.forwarding.snapshots == [draft, draft, nil])
        }
    }

    @Test func beforeIOReorderingCreatesFreshCatchUpAttempt() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let firstDraft = fixture.draft()
            let before = await fixture.forwarding.hold(.beforeSave(1))
            let first = fixture.start { await fixture.commit(firstDraft) }
            try #require(await before.waitForEntry())
            let older = try fixture.attempt()
            #expect(await fixture.store.load() == .absent)
            let secondDraft = fixture.draft(1)
            #expect(await fixture.commit(secondDraft))
            let second = try fixture.attempt()
            #expect(second !== older)
            let catchUpGate = await fixture.forwarding.hold(.afterSave(3))
            await before.release()
            try #require(await catchUpGate.waitForEntry())
            let catchUp = try fixture.attempt()
            #expect(older.observation == .mutation(snapshot: firstDraft, outcome: .writeCompleted))
            #expect(second.observation == .mutation(snapshot: secondDraft, outcome: .writeCompleted))
            #expect(catchUp !== older && catchUp !== second)
            #expect(catchUp.observation == .mutation(snapshot: secondDraft, outcome: nil))
            await catchUpGate.release()
            #expect(await first.value == false)
            #expect(fixture.owner.latestStorageAttempt === catchUp)
            #expect(catchUp.observation == .mutation(snapshot: secondDraft, outcome: .writeCompleted))
            #expect(await fixture.forwarding.snapshots == [firstDraft, secondDraft, secondDraft])
        }
    }

    @Test func delayedResultWithABASnapshotsNeverPromotesOldRecord() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let draft = fixture.draft()
            let after = await fixture.forwarding.hold(.afterSave(1))
            let first = fixture.start { await fixture.commit(draft) }
            try #require(await after.waitForEntry())
            let older = try fixture.attempt()
            #expect(await fixture.store.load() == .loaded(draft))
            #expect(older.observation == .mutation(snapshot: draft, outcome: nil))
            let middle = fixture.draft(1)
            #expect(await fixture.commit(middle))
            let middleAttempt = try fixture.attempt()
            #expect(await fixture.commit(draft))
            let latest = try fixture.attempt()
            #expect(latest !== older && latest !== middleAttempt)
            await after.release()
            #expect(await first.value)
            #expect(older.observation == .mutation(snapshot: draft, outcome: .writeCompleted))
            #expect(latest.observation == older.observation)
            #expect(middleAttempt.observation == .mutation(snapshot: middle, outcome: .writeCompleted))
            #expect(fixture.owner.latestStorageAttempt === latest)
            #expect(await fixture.forwarding.snapshots == [draft, middle, draft])
        }
    }

    @Test func delayedLoadedResultCompletesOnlyItsOwnRecord() async throws {
        try await PendingPersistenceFixture.run { fixture in
            let draft = try await fixture.build()
            let gate = await fixture.forwarding.hold(.afterLoad(1))
            let load = fixture.start { await fixture.owner.load() }
            try #require(await gate.waitForEntry())
            let read = try fixture.attempt()
            let newerDraft = fixture.draft(1)
            #expect(await fixture.commit(newerDraft))
            let mutation = try fixture.attempt()
            await gate.release()
            await load.value
            #expect(read.observation == .load(.loaded(draft)))
            #expect(mutation.observation == .mutation(snapshot: newerDraft, outcome: .writeCompleted))
            #expect(fixture.owner.latestStorageAttempt === mutation)
            #expect(fixture.owner.pendingStudioDraft == newerDraft)
        }
    }

    @Test func gatesReleasedBeforeEntryAndThrowingTeardownJoinTasks() async throws {
        enum SetupFailure: Error { case expected }
        try await PendingPersistenceFixture.run { fixture in
            let gate = await fixture.forwarding.hold(.beforeSave(1))
            await gate.release()
            let draft = fixture.draft()
            let commit = fixture.start { await fixture.commit(draft) }
            #expect(await commit.value)
            #expect(await gate.waitForEntry())
            #expect(await fixture.forwarding.snapshots == [draft])
        }
        var ownedRoot: URL?
        var task: Task<Bool, Never>?
        do {
            try await PendingPersistenceFixture.run { fixture in
                ownedRoot = fixture.root
                let before = await fixture.forwarding.hold(.beforeSave(1))
                _ = await fixture.forwarding.hold(.afterSave(1))
                let draft = fixture.draft()
                task = fixture.start { await fixture.commit(draft) }
                try #require(await before.waitForEntry())
                throw SetupFailure.expected
            }
            Issue.record("Expected setup failure")
        } catch SetupFailure.expected {
            let root = try #require(ownedRoot)
            #expect(!FileManager.default.fileExists(atPath: root.path))
            // Teardown released both the entered gate and the not-yet-entered result gate.
            #expect(await task?.value == false)
        }
    }
}
