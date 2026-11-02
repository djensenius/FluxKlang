import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantModelGeneratorIsolationTests {
    @Test func concreteConstructionIsPassive() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())

        _ = FoundationModelAssistantGenerator(coordinator: coordinator, mirroring: audit)

        expectAudit(audit, attempts: 0)
    }

    @Test func isolatedAvailabilityIsDeterministicWithoutFrameworkAccess() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let generator = FoundationModelAssistantGenerator(coordinator: coordinator, mirroring: audit)

        #expect(await generator.availability() == .deterministic)

        expectAudit(audit, attempts: 1)
    }

    @Test func repeatedStreamsDenyWithoutEventsOrDraftChanges() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let fixture = AssistantRoutingFixture()
        let prior = try fixture.prepared()
        let store = RoutingTestDraftStore()
        await store.save(prior)
        let coordinator = AssistantCoordinator(draftStore: store)
        await coordinator.load()
        #expect(coordinator.pendingStudioDraft == prior)
        let generator = FoundationModelAssistantGenerator(coordinator: coordinator, mirroring: audit)
        let request = AssistantGenerationRequest(
            question: "Help", recentMessages: [], summary: "", context: fixture.context)
        expectAudit(audit, attempts: 0)

        for attempt in 1...2 {
            try #require(AppPersistence.isTesting)
            try #require(AssistantServiceIsolation.deniesLiveServices)
            var events = 0
            do {
                for try await _ in generator.stream(request) { events += 1 }
                Issue.record("Expected isolation denial")
            } catch AssistantServiceIsolation.AccessError.denied {
                // The concrete boundary must preserve this exact error.
            } catch {
                Issue.record("Expected AssistantServiceIsolation.AccessError.denied")
            }
            #expect(events == 0)
            #expect(coordinator.pendingStudioDraft == prior)
            #expect(await store.load() == prior)
            #expect(await store.saves == 1)
            expectAudit(audit, attempts: UInt64(attempt))
        }
    }

    // Local mirrors describe these paths only, not global callsite coverage.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64) {
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.passiveConstruction, for: .assistantModelGenerator) == 1)
        #expect(snapshot.count(.attempted, for: .assistantModelGenerator) == attempts)
        #expect(snapshot.count(.denied, for: .assistantModelGenerator) == attempts)
        #expect(snapshot.count(.factoryEvaluated, for: .assistantModelGenerator) == 0)
        #expect(snapshot.count(.apiEntered, for: .assistantModelGenerator) == 0)
    }
}
