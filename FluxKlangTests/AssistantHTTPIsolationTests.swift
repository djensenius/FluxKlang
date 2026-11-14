import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantHTTPIsolationTests {
    @Test func concreteConstructionIsPassive() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()

        _ = URLSessionAssistantHTTPClient(mirroring: audit)

        expectAudit(audit, attempts: 0, constructions: 1)
    }

    @Test func isolatedDefaultNeverEvaluatesProductionFactory() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()

        let client = URLSessionAssistantHTTPClient.defaultClient(mirroring: audit)

        #expect(client == nil)
        expectAudit(audit, attempts: 0, constructions: 0)
    }

    @Test func repeatedConcreteRequestsDenyBeforeSessionAccess() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let client = URLSessionAssistantHTTPClient(mirroring: audit)
        let url = try #require(URL(string: "https://example.invalid"))
        let request = URLRequest(url: url)
        expectAudit(audit, attempts: 0, constructions: 1)

        for attempt in 1...2 {
            try #require(AppPersistence.isTesting)
            try #require(AssistantServiceIsolation.deniesLiveServices)
            do {
                _ = try await client.data(for: request)
                Issue.record("Expected isolation denial")
            } catch AssistantServiceIsolation.AccessError.denied {
                // The concrete boundary must preserve this exact error.
            } catch {
                Issue.record("Expected AssistantServiceIsolation.AccessError.denied")
            }
            expectAudit(audit, attempts: UInt64(attempt), constructions: 1)
        }
    }

    // Local mirrors describe these paths only, not global callsite coverage.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64, constructions: UInt64) {
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .assistantHTTP) == attempts)
        #expect(snapshot.count(.denied, for: .assistantHTTP) == attempts)
        #expect(snapshot.count(.passiveConstruction, for: .assistantHTTP) == constructions)
        #expect(snapshot.count(.factoryEvaluated, for: .assistantHTTP) == 0)
        #expect(snapshot.count(.apiEntered, for: .assistantHTTP) == 0)
    }
}
