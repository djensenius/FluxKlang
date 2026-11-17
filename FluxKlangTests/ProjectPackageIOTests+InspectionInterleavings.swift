import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectPackageIOTests {
    private typealias Session = ProjectPackageInspectionSession
    private typealias Refusal = ProjectPackageInspectionSessionRefusal

    @MainActor @Test func inspectionSessionCancelBeforeLoaderEntryDrainsThroughCleanup() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = try session.openWindow(WindowID(uuid: UUID()))
            fixture.probe.stages.withLock { $0 = [.beforeLoader, .cleanup] }
            let request = try fixture.begin(window)
            #expect(session.acquisition?.request === request)
            #expect(session.cancel(request))
            try await fixture.waitForEntry(fixture.probe.beforeLoader, of: request)
            #expect(fixture.probe.observations.withLock { $0.loaderEntries } == 0)
            #expect(session.acquisition?.phase == .draining)
            #expect(throws: Refusal.busy) { try fixture.begin(window) }
            fixture.probe.beforeLoader.release()
            try await fixture.waitForEntry(fixture.probe.cleanup, of: request)
            #expect(fixture.probe.observations.withLock { $0.cancelledAtLoaderEntry })
            #expect(fixture.probe.observations.withLock { $0.witnesses } == 1)
            #expect(request.outcome == nil)
            #expect(session.acquisition?.request === request)
            #expect(throws: Refusal.busy) { try fixture.begin(window) }
            fixture.probe.cleanup.release()
            await request.join()
            #expect(request.outcome == .cancelled)
            #expect(session.acquisition == nil)
            #expect(try session.inspection(in: window) == nil)
            #expect(fixture.probe.observations.withLock { $0.calls } == 1)
            #expect(fixture.probe.observations.withLock { $0.witnesses } == 0)
        }
    }

    @MainActor @Test func inspectionSessionCancelDuringChunkPreservesPreviousPayloadAndSlot() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = try session.openWindow(WindowID(uuid: UUID()))
            let original = try await fixture.retain(window)
            fixture.probe.stages.withLock { $0 = [.chunk, .cleanup] }
            let request = try fixture.begin(window, at: fixture.replacement)
            try await fixture.waitForEntry(fixture.probe.chunk, of: request)
            #expect(session.cancel(request))
            #expect(session.cancel(request))
            #expect(try session.inspection(in: window) == original)
            #expect(session.acquisition?.phase == .draining)
            #expect(throws: Refusal.busy) { try fixture.begin(window) }
            #expect(fixture.probe.observations.withLock { $0.witnesses } == 1)
            fixture.probe.chunk.release()
            try await fixture.waitForEntry(fixture.probe.cleanup, of: request)
            #expect(request.outcome == nil)
            #expect(session.acquisition?.request === request)
            #expect(try session.inspection(in: window) == original)
            #expect(fixture.probe.observations.withLock { $0.witnesses } == 1)
            fixture.probe.cleanup.release()
            await request.join()
            #expect(request.outcome == .cancelled)
            #expect(try session.inspection(in: window) == original)
            #expect(session.acquisition == nil)
            #expect(fixture.probe.observations.withLock { $0.maximumActive } == 1)
        }
    }

    @MainActor @Test func inspectionSessionCancelAfterDecodeRejectsSuccessfulStalePublication() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = try session.openWindow(WindowID(uuid: UUID()))
            let original = try await fixture.retain(window)
            fixture.probe.stages.withLock { $0 = [.decoded, .cleanup] }
            let request = try fixture.begin(window, at: fixture.replacement)
            try await fixture.waitForEntry(fixture.probe.decoded, of: request)
            #expect(fixture.probe.observations.withLock { $0.decoded } == 2)
            #expect(session.cancel(request))
            #expect(try session.inspection(in: window) == original)
            fixture.probe.decoded.release()
            try await fixture.waitForEntry(fixture.probe.cleanup, of: request)
            #expect(throws: Refusal.busy) { try fixture.begin(window) }
            #expect(session.acquisition?.request === request)
            fixture.probe.cleanup.release()
            await request.join()
            #expect(request.outcome == .cancelled)
            #expect(try session.inspection(in: window) == original)
            #expect(session.acquisition == nil)
        }
    }

    @MainActor @Test func inspectionSessionReopenCannotReviveOldRequestOrCancelItsSuccessor() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let identity = WindowID(uuid: UUID())
            let window = try session.openWindow(identity)
            _ = try await fixture.retain(window)
            fixture.probe.stages.withLock { $0 = [.decoded] }
            let old = try fixture.begin(window, at: fixture.replacement)
            try await fixture.waitForEntry(fixture.probe.decoded, of: old)
            try session.closeWindow(window)
            #expect(session.retainedCount == 0)
            let reopened = try session.openWindow(identity)
            #expect(reopened != window)
            #expect(!session.cancel(old))
            #expect(throws: Refusal.invalidRegistration) { try session.closeWindow(window) }
            #expect(throws: Refusal.invalidRegistration) {
                try fixture.begin(window)
            }
            #expect(throws: Refusal.busy) { try fixture.begin(reopened) }
            fixture.probe.decoded.release()
            await old.join()
            #expect(old.outcome == .cancelled)
            #expect(try session.inspection(in: reopened) == nil)
            fixture.probe.stages.withLock { $0 = [.chunk] }
            let later = try fixture.begin(reopened)
            try await fixture.waitForEntry(fixture.probe.chunk, of: later)
            #expect(!session.cancel(old))
            await old.join()
            #expect(session.acquisition?.request === later)
            #expect(session.acquisition?.phase == .acquiring)
            fixture.probe.chunk.release()
            await later.join()
            #expect(later.outcome == .published)
            #expect(try session.inspection(in: reopened) != nil)
            #expect(fixture.probe.observations.withLock { $0.maximumActive } == 1)
        }
    }

    @MainActor @Test func inspectionSessionClosingOtherWindowDoesNotCancelOrFreeAcquisition() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let first = try session.openWindow(WindowID(uuid: UUID()))
            let second = try session.openWindow(WindowID(uuid: UUID()))
            let third = try session.openWindow(WindowID(uuid: UUID()))
            _ = try await fixture.retain(first)
            _ = try await fixture.retain(second)
            fixture.probe.stages.withLock { $0 = [.decoded] }
            let request = try fixture.begin(first, at: fixture.replacement)
            try await fixture.waitForEntry(fixture.probe.decoded, of: request)
            try session.closeWindow(second)
            #expect(session.retainedCount == 1)
            #expect(session.acquisition?.request === request)
            #expect(session.acquisition?.phase == .acquiring)
            #expect(throws: Refusal.busy) { try fixture.begin(third) }
            let foreign = Session()
            #expect(!foreign.cancel(request))
            fixture.probe.decoded.release()
            await request.join()
            #expect(request.outcome == .published)
            #expect(session.retainedCount == 1)
            #expect(try session.inspection(in: third) == nil)
            #expect(fixture.probe.observations.withLock { $0.calls } == 3)
        }
    }

    @MainActor @Test func inspectionSessionCloseInspectionReleasesPayloadButNotDrainingSlot() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = try session.openWindow(WindowID(uuid: UUID()))
            _ = try await fixture.retain(window)
            fixture.probe.stages.withLock { $0 = [.decoded] }
            let request = try fixture.begin(window, at: fixture.replacement)
            try await fixture.waitForEntry(fixture.probe.decoded, of: request)
            try session.closeInspection(in: window)
            #expect(session.retainedCount == 0)
            #expect(session.windowCount == 1)
            #expect(try session.inspection(in: window) == nil)
            #expect(session.acquisition?.phase == .draining)
            #expect(throws: Refusal.busy) { try fixture.begin(window) }
            fixture.probe.decoded.release()
            await request.join()
            #expect(request.outcome == .cancelled)
            #expect(try session.inspection(in: window) == nil)
            #expect(session.acquisition == nil)
        }
    }

    @MainActor @Test func inspectionSessionGateReportsMainThreadWithoutBlocking() async {
        let gate = InspectionTestGate()
        withKnownIssue("Deliberately invoke the blocking hook on main without releasing it first") {
            gate.blockOnce()
        } matching: { issue in
            guard case .unconditional = issue.kind else { return false }
            return issue.comments == [InspectionTestGate.mainThreadFailure]
        }
        await gate.entered.wait()
        #expect(gate.blockedOnMain.withLock { $0 })
        gate.release()
    }

    @MainActor @Test func inspectionSessionGateWaitReportsEarlyLoaderFailureAndJoinsCleanup() async throws {
        for stage in [InspectionAcquisitionProbe.Stage.chunk, .decoded] {
            var scratch: URL?
            await #expect(throws: InspectionSessionFixture.EntryFailure.completedBeforeEntry(.refused(.notFound))) {
                try await InspectionSessionFixture.run { fixture in
                    scratch = fixture.scratch
                    let window = try fixture.session.openWindow(WindowID(uuid: UUID()))
                    fixture.probe.stages.withLock { $0 = [stage, .cleanup] }
                    let request = try fixture.begin(window, at: fixture.scratch.appendingPathComponent("absent"))
                    let gate = stage == .chunk ? fixture.probe.chunk : fixture.probe.decoded
                    try await fixture.waitForEntry(gate, of: request)
                }
            }
            let removed = try #require(scratch)
            #expect(!FileManager.default.fileExists(atPath: removed.path))
        }
    }

    @MainActor @Test func inspectionSessionEveryUnenteredGateObservesRequestCompletion() async throws {
        try await InspectionSessionFixture.run { fixture in
            let window = try fixture.session.openWindow(WindowID(uuid: UUID()))
            let request = try fixture.begin(window, at: fixture.scratch.appendingPathComponent("absent"))
            let gates = [fixture.probe.beforeLoader, fixture.probe.chunk, fixture.probe.decoded, fixture.probe.cleanup]
            for gate in gates {
                await #expect(throws: InspectionSessionFixture.EntryFailure.completedBeforeEntry(.refused(.notFound))) {
                    try await fixture.waitForEntry(gate, of: request)
                }
            }
            await request.join()
            #expect(fixture.session.acquisition == nil)
        }
    }

    @Test func inspectionSessionSignalResumesOnceAcrossEntryCompletionAndReleaseRaces() async {
        for first in [0, 1] {
            let signal = InspectionTestSignal<Int>()
            let observed = Mutex<[Int]>([])
            _ = signal.observe { value in observed.withLock { $0.append(value) } }
            let removed = signal.observe { _ in Issue.record("Removed observer must not run") }
            signal.removeObserver(removed)
            signal.signal(first)
            signal.signal(1 - first)
            #expect(await signal.wait() == first)
            #expect(observed.withLock { $0 } == [first])
        }
        let signal = InspectionTestSignal<Int>()
        let observed = Mutex<[Int]>([])
        _ = signal.observe { value in observed.withLock { $0.append(value) } }
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<16 { group.addTask { signal.signal(value) } }
        }
        let winner = await signal.wait()
        #expect(observed.withLock { $0 } == [winner])
        let gate = InspectionTestGate()
        gate.release()
        await gate.pause()
        await gate.entered.wait()
        gate.release()
    }
}
