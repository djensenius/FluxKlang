import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantInterpreterAvailabilityTests {
    @Test(arguments: [nil, .model, .routing] as [FoundationModelActionInterpreter.LiveTestPurpose?])
    func concreteConstructionIsPassive(_ purpose: FoundationModelActionInterpreter.LiveTestPurpose?) throws {
        try requireIsolatedProcess()
        let audit = ProductionAccessAudit()

        _ = makeInterpreter(purpose, mirroring: audit)

        expectAudit(audit, attempts: 0)
    }

    @Test(arguments: [nil, .model, .routing] as [FoundationModelActionInterpreter.LiveTestPurpose?])
    func repeatedAvailabilityDeniesWithoutFrameworkAccess(
        _ purpose: FoundationModelActionInterpreter.LiveTestPurpose?
    ) async throws {
        try requireIsolatedProcess()
        let audit = ProductionAccessAudit()
        let interpreter = makeInterpreter(purpose, mirroring: audit)
        expectAudit(audit, attempts: 0)

        for attempt in 1...2 {
            #expect(await interpreter.availability() == .unavailable(AssistantServiceIsolation.reason))
            expectAudit(audit, attempts: UInt64(attempt))
        }
    }

    private func requireIsolatedProcess() throws {
        let environment = ProcessInfo.processInfo.environment
        let modelFlagEnabled = environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] == "1"
        let routingFlagEnabled = environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "1"
        let modelPermitted = FoundationModelActionInterpreter.LiveTestPurpose.model.isPermitted(
            environment: environment)
        let routingPermitted = FoundationModelActionInterpreter.LiveTestPurpose.routing.isPermitted(
            environment: environment)
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        try #require(!modelFlagEnabled)
        try #require(!routingFlagEnabled)
        try #require(!modelPermitted)
        try #require(!routingPermitted)
    }

    private func makeInterpreter(
        _ purpose: FoundationModelActionInterpreter.LiveTestPurpose?, mirroring audit: ProductionAccessAudit
    ) -> FoundationModelActionInterpreter {
        if let purpose {
            return .forLiveTesting(purpose, mirroring: audit)
        }
        return FoundationModelActionInterpreter(mirroring: audit)
    }

    // Local mirrors describe construction and denied availability only, not generation or global coverage.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64) {
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.passiveConstruction, for: .assistantActionInterpreter) == 1)
        #expect(snapshot.count(.attempted, for: .assistantActionInterpreter) == attempts)
        #expect(snapshot.count(.denied, for: .assistantActionInterpreter) == attempts)
        #expect(snapshot.count(.factoryEvaluated, for: .assistantActionInterpreter) == 0)
        #expect(snapshot.count(.apiEntered, for: .assistantActionInterpreter) == 0)
    }
}
