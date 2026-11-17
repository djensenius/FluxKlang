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
}
