import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectPackageIOTests {
    private typealias Session = ProjectPackageInspectionSession
    private typealias Refusal = ProjectPackageInspectionSessionRefusal

    @MainActor @Test func inspectionSessionBoundsWindowsAndRejectsForeignAndRetiredRegistrations() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = WindowID(uuid: UUID())
            let first = try session.openWindow(window)
            #expect(try session.openWindow(window) == first)
            let foreign = Session()
            let foreignRegistration = try foreign.openWindow(window)
            #expect(throws: Refusal.invalidRegistration) {
                try fixture.begin(foreignRegistration)
            }
            #expect(throws: Refusal.invalidRegistration) { try session.closeWindow(foreignRegistration) }
            #expect(throws: Refusal.invalidRegistration) { try session.closeInspection(in: foreignRegistration) }
            #expect(throws: Refusal.invalidRegistration) { try session.inspection(in: foreignRegistration) }
            for _ in 1..<16 { _ = try session.openWindow(WindowID(uuid: UUID())) }
            #expect(Session.windowLimit == 16)
            #expect(session.windowCount == 16)
            #expect(throws: Refusal.windowCapacity) { try session.openWindow(WindowID(uuid: UUID())) }
            try session.closeWindow(first)
            let reopened = try session.openWindow(window)
            #expect(reopened != first)
            #expect(throws: Refusal.invalidRegistration) {
                try fixture.begin(first)
            }
            #expect(session.windowCount == 16)
            #expect(fixture.probe.observations.withLock { $0.calls } == 0)
        }
    }

    @MainActor @Test func inspectionSessionRetainsTwoAndNeverQueuesAThird() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let first = try session.openWindow(WindowID(uuid: UUID()))
            let second = try session.openWindow(WindowID(uuid: UUID()))
            let third = try session.openWindow(WindowID(uuid: UUID()))
            _ = try await fixture.retain(first)
            _ = try await fixture.retain(second)
            #expect(Session.retainedLimit == 2)
            #expect(session.retainedCount == 2)
            #expect(throws: Refusal.retainedCapacity) {
                try fixture.begin(third)
            }
            #expect(fixture.probe.observations.withLock { $0.calls } == 2)
            try session.closeInspection(in: first)
            #expect(session.retainedCount == 1)
            #expect(session.acquisition == nil)
            #expect(try session.inspection(in: third) == nil)
            #expect(fixture.probe.observations.withLock { $0.calls } == 2)
            _ = try await fixture.retain(third)
            #expect(fixture.probe.observations.withLock { $0.calls } == 3)
            #expect(fixture.probe.observations.withLock { $0.maximumActive } == 1)
        }
    }

    @MainActor @Test func inspectionSessionPublishesReplacementOnlyOnEligibleSuccess() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = try session.openWindow(WindowID(uuid: UUID()))
            let other = try session.openWindow(WindowID(uuid: UUID()))
            let original = try await fixture.retain(window)
            _ = try await fixture.retain(other)
            fixture.probe.stages.withLock { $0 = [.decoded] }
            let request = try fixture.begin(window, at: fixture.replacement)
            #expect(session.acquisition?.request === request)
            #expect(session.acquisition?.phase == .acquiring)
            #expect(try session.inspection(in: window) == original)
            try await fixture.waitForEntry(fixture.probe.decoded, of: request)
            #expect(try session.inspection(in: window) == original)
            #expect(request.outcome == nil)
            fixture.probe.decoded.release()
            await request.join()
            #expect(request.outcome == .published)
            let replacement = try #require(try session.inspection(in: window))
            #expect(replacement != original)
            #expect(replacement.documents.contents.files.first { $0.path == "unknown.bin" }?.bytes == Data([9, 8, 7]))
            #expect(session.retainedCount == 2)
            #expect(session.acquisition == nil)
            await request.join()
        }
    }

    @MainActor @Test func inspectionSessionFailurePreservesTheWholePreviousPayload() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = try session.openWindow(WindowID(uuid: UUID()))
            let original = try await fixture.retain(window)
            let request = try fixture.begin(window, at: fixture.scratch.appendingPathComponent("absent"))
            #expect(try session.inspection(in: window) == original)
            await request.join()
            #expect(request.outcome == .refused(.notFound))
            #expect(try session.inspection(in: window) == original)
            #expect(session.retainedCount == 1)
            #expect(session.acquisition == nil)
        }
    }

    @MainActor @Test func inspectionSessionDefaultOperationUsesTheAcceptedLoader() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = Session()
            let window = try session.openWindow(WindowID(uuid: UUID()))
            let request = try session.beginInspection(at: fixture.original, in: window)
            await request.join()
            #expect(request.outcome == .published)
            let expected = try await ProjectPackageInspectionLoader().load(at: fixture.original)
            #expect(try session.inspection(in: window) == expected)
            #expect(!fixture.session.cancel(request))
            #expect(!session.cancel(request))
            try session.closeWindow(window)
            #expect(session.retainedCount == 0)
            #expect(session.windowCount == 0)
            for refusal in Refusal.allCases { #expect(Mirror(reflecting: refusal).children.isEmpty) }
        }
    }

    private typealias Model = PerformancePackageInspectionWindow
    private typealias Content = PerformanceWorkspaceContent

    @MainActor @Test func inspectionWindowPublishesAfterCompletionAndPreservesStarter() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = WindowID(uuid: UUID())
            let starter = try PerformanceProjectSession(window: window)
            try starter.setStereoConnectionEnabled(false)
            try starter.undo()
            let before = (starter.project, starter.base, starter.snapshot, starter.navigation)
            let model = fixture.track(Model(owner: session, window: window))
            #expect(model.status == .idle)
            #expect(!model.isInspecting)
            #expect(session.windowCount == 1)
            fixture.probe.stages.withLock { $0 = [.decoded] }
            model.open(at: fixture.original)
            #expect(model.status == .opening)
            #expect(model.isOpening && model.isInspecting)
            let request = try #require(session.acquisition?.request)
            try await fixture.waitForEntry(fixture.probe.decoded, of: request)
            #expect(model.inspection == nil)
            #expect(Content.resolve(starter: starter, window: window, isInspecting: model.isInspecting)
                == .inspection(returnTitle: "Return to Unsaved Project"))
            fixture.probe.decoded.release()
            await model.join()
            #expect(model.status == .idle)
            #expect(!model.isOpening)
            let published = try #require(model.inspection)
            #expect(try session.inspection(in: session.openWindow(window)) == published)
            #expect(session.retainedCount == 1)
            model.returnToUnsavedProject()
            #expect(model.inspection == nil)
            #expect(!model.isInspecting)
            #expect(session.retainedCount == 0)
            #expect(Content.resolve(starter: starter, window: window, isInspecting: model.isInspecting) == .editor)
            #expect(before == (starter.project, starter.base, starter.snapshot, starter.navigation))
            #expect(starter.snapshot.history.redoCount == 1)
        }
    }

    @MainActor @Test func inspectionWindowRefusalsNeverDisturbOrQueue() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let model = fixture.track(Model(owner: session, window: WindowID(uuid: UUID())))
            model.open(at: fixture.original)
            await model.join()
            let original = try #require(model.inspection)
            fixture.probe.stages.withLock { $0 = [.decoded] }
            let other = try fixture.begin(session.openWindow(WindowID(uuid: UUID())))
            try await fixture.waitForEntry(fixture.probe.decoded, of: other)
            model.open(at: fixture.replacement)
            #expect(model.status == .unavailable(.busy))
            #expect(model.inspection == original)
            #expect(!model.isOpening)
            fixture.probe.decoded.release()
            await other.join()
            fixture.probe.stages.withLock { $0 = [.beforeLoader] }
            model.open(at: fixture.replacement)
            let pending = try #require(session.acquisition?.request)
            try await fixture.waitForEntry(fixture.probe.beforeLoader, of: pending)
            model.open(at: fixture.original)
            #expect(model.status == .unavailable(.busy))
            #expect(model.isOpening)
            #expect(model.inspection == original)
            #expect(session.acquisition?.request === pending)
            fixture.probe.beforeLoader.release()
            await model.join()
            #expect(model.status == .idle)
            let replacement = try #require(model.inspection)
            #expect(replacement != original)
            let third = fixture.track(Model(owner: session, window: WindowID(uuid: UUID())))
            third.open(at: fixture.original)
            #expect(third.status == .unavailable(.retainedCapacity))
            #expect(third.inspection == nil && !third.isOpening)
            // A refused fresh window stays visible until Return.
            #expect(third.isInspecting)
            third.returnToUnsavedProject()
            #expect(!third.isInspecting)
            #expect(Content.resolve(starter: nil, window: WindowID(uuid: UUID()), isInspecting: third.isInspecting)
                == .empty)
            #expect(session.acquisition == nil)
            #expect(model.inspection == replacement)
            #expect(fixture.probe.observations.withLock { $0.calls } == 3)
            #expect(fixture.probe.observations.withLock { $0.maximumActive } == 1)
        }
    }

    @MainActor @Test func inspectionWindowFailureAndCancelKeepPreviousPayload() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let model = fixture.track(Model(owner: session, window: WindowID(uuid: UUID())))
            model.open(at: fixture.original)
            await model.join()
            let original = try #require(model.inspection)
            model.open(at: fixture.scratch.appendingPathComponent("absent"))
            await model.join()
            #expect(model.status == .refused(.notFound))
            #expect(model.inspection == original)
            #expect(model.isInspecting)
            fixture.probe.stages.withLock { $0 = [.beforeLoader] }
            model.open(at: fixture.replacement)
            let pending = try #require(session.acquisition?.request)
            try await fixture.waitForEntry(fixture.probe.beforeLoader, of: pending)
            model.cancelOpening()
            #expect(model.status == .cancelling)
            #expect(model.isOpening)
            #expect(session.acquisition?.phase == .draining)
            #expect(model.inspection == original)
            fixture.probe.beforeLoader.release()
            await model.join()
            #expect(model.status == .cancelled)
            #expect(!model.isOpening)
            #expect(model.inspection == original)
            #expect(session.acquisition == nil)
            model.cancelOpening()
            #expect(model.status == .cancelled)
        }
    }

    @MainActor @Test func inspectionWindowReturnDuringOpeningRejectsLateSuccess() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = WindowID(uuid: UUID())
            let starter = try PerformanceProjectSession(window: window)
            let model = fixture.track(Model(owner: session, window: window))
            model.open(at: fixture.original)
            await model.join()
            fixture.probe.stages.withLock { $0 = [.decoded] }
            model.open(at: fixture.replacement)
            let pending = try #require(session.acquisition?.request)
            try await fixture.waitForEntry(fixture.probe.decoded, of: pending)
            model.returnToUnsavedProject()
            #expect(model.status == .idle)
            #expect(model.inspection == nil)
            #expect(!model.isOpening && !model.isInspecting)
            #expect(session.retainedCount == 0)
            #expect(session.acquisition?.phase == .draining)
            fixture.probe.decoded.release()
            await model.join()
            #expect(pending.outcome == .cancelled)
            #expect(model.status == .idle)
            #expect(model.inspection == nil)
            #expect(!model.isInspecting)
            #expect(try session.inspection(in: session.openWindow(window)) == nil)
            #expect(Content.resolve(starter: starter, window: window, isInspecting: model.isInspecting) == .editor)
        }
    }

    @MainActor @Test func inspectionWindowCloseRetiresRegistrationAndIgnoresLateCompletion() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            let window = WindowID(uuid: UUID())
            let model = fixture.track(Model(owner: session, window: window))
            model.open(at: fixture.original)
            await model.join()
            fixture.probe.stages.withLock { $0 = [.decoded] }
            model.open(at: fixture.replacement)
            let pending = try #require(session.acquisition?.request)
            try await fixture.waitForEntry(fixture.probe.decoded, of: pending)
            model.close()
            #expect(session.windowCount == 0)
            #expect(session.retainedCount == 0)
            #expect(session.acquisition?.phase == .draining)
            #expect(model.inspection == nil && model.status == .idle)
            #expect(!model.isInspecting && !model.isOpening)
            model.close()
            model.open(at: fixture.original)
            #expect(session.acquisition?.request === pending)
            fixture.probe.decoded.release()
            await model.join()
            #expect(pending.outcome == .cancelled)
            #expect(model.inspection == nil && model.status == .idle)
            #expect(session.acquisition == nil)
            #expect(fixture.probe.observations.withLock { $0.calls } == 2)
            let reopened = fixture.track(Model(owner: session, window: window))
            #expect(reopened.status == .idle)
            #expect(session.windowCount == 1)
            #expect(try session.inspection(in: session.openWindow(window)) == nil)
            reopened.open(at: fixture.original)
            await reopened.join()
            #expect(reopened.inspection != nil)
            try session.closeWindow(session.openWindow(window))
            reopened.returnToUnsavedProject()
            #expect(reopened.status == .unavailable(.invalidRegistration))
            #expect(reopened.inspection == nil)
            #expect(!reopened.isInspecting && !reopened.isOpening)
            reopened.open(at: fixture.original)
            #expect(session.acquisition == nil)
            #expect(fixture.probe.observations.withLock { $0.calls } == 3)
        }
    }

    @MainActor @Test func inspectionWindowCapacityRefusalIsTypedAndInert() async throws {
        try await InspectionSessionFixture.run { fixture in
            let session = fixture.session
            for _ in 0..<Session.windowLimit { _ = try session.openWindow(WindowID(uuid: UUID())) }
            let window = WindowID(uuid: UUID())
            let model = fixture.track(Model(owner: session, window: window))
            #expect(model.status == .unavailable(.windowCapacity))
            #expect(!model.isInspecting)
            model.open(at: fixture.original)
            model.cancelOpening()
            model.returnToUnsavedProject()
            model.close()
            await model.join()
            #expect(model.status == .unavailable(.windowCapacity))
            #expect(model.inspection == nil && !model.isOpening)
            #expect(session.acquisition == nil)
            #expect(session.windowCount == Session.windowLimit)
            #expect(fixture.probe.observations.withLock { $0.calls } == 0)
            #expect(Content.resolve(starter: nil, window: window, isInspecting: model.isInspecting) == .empty)
        }
    }

    @MainActor @Test func workspaceContentPrefersInspectionWithTruthfulReturn() throws {
        let window = WindowID(uuid: UUID())
        let other = WindowID(uuid: UUID())
        #expect(Content.resolve(starter: nil, window: window, isInspecting: false) == .empty)
        #expect(Content.resolve(starter: nil, window: window, isInspecting: true)
            == .inspection(returnTitle: "Close Inspection"))
        let starter = try PerformanceProjectSession(window: window)
        #expect(Content.resolve(starter: starter, window: window, isInspecting: false) == .editor)
        #expect(Content.resolve(starter: starter, window: window, isInspecting: true)
            == .inspection(returnTitle: "Return to Unsaved Project"))
        #expect(Content.resolve(starter: starter, window: other, isInspecting: false) == .retained)
        #expect(Content.resolve(starter: starter, window: other, isInspecting: true)
            == .inspection(returnTitle: "Return to Unsaved Project"))
        #expect(starter.navigation.windowProjects == [window: starter.project.id])
    }
}
