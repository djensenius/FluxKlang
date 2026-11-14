import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantInterpreterGenerationTests {
    @Test(arguments: [nil, .model, .routing] as [FoundationModelActionInterpreter.LiveTestPurpose?],
          ["lower channel 7 by 3 dB", "route Atlas through Echo to mains"])
    func interpretationDeniesWithoutAvailabilityOrGeneration(
        _ purpose: FoundationModelActionInterpreter.LiveTestPurpose?, text: String
    ) async throws {
        try requireIsolatedProcess()
        let audit = ProductionAccessAudit()
        let interpreter = makeInterpreter(purpose, mirroring: audit)

        await expectIsolationDenial(interpreter, text: text)

        expectAudit(audit, attempts: 1)
    }

    @Test(arguments: [String(repeating: "a", count: 2_001), "Hello"])
    func policyDenialPrecedesValidationAndNonActionHandling(_ text: String) async throws {
        try requireIsolatedProcess()
        let audit = ProductionAccessAudit()
        let interpreter = FoundationModelActionInterpreter(mirroring: audit)

        await expectIsolationDenial(interpreter, text: text)

        expectAudit(audit, attempts: 1)
    }

    @Test func alreadyCancelledChildDoesNotAttemptInterpretation() async throws {
        try requireIsolatedProcess()
        let audit = ProductionAccessAudit()
        let interpreter = FoundationModelActionInterpreter(mirroring: audit)
        #expect(!Task.isCancelled)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                #expect(Task.isCancelled)
                do {
                    _ = try await interpreter.interpret(.init(text: "lower channel 7 by 3 dB"))
                    Issue.record("Expected CancellationError")
                } catch is CancellationError {
                    // Cancellation must precede the public attempt and policy check.
                } catch {
                    Issue.record("Expected CancellationError")
                }
            }
            await group.waitForAll()
        }

        #expect(!Task.isCancelled)
        expectAudit(audit, attempts: 0)
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

    private func expectIsolationDenial(_ interpreter: FoundationModelActionInterpreter, text: String) async {
        do {
            _ = try await interpreter.interpret(.init(text: text))
            Issue.record("Expected isolation unavailable error")
        } catch FoundationModelActionInterpreter.InterpretationError.unavailable {
            // Preserve the concrete boundary's exact existing error.
        } catch {
            Issue.record("Expected FoundationModelActionInterpreter.InterpretationError.unavailable")
        }
    }

    // Local mirrors describe denied and cancelled paths only, not allowed generation or global coverage.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64) {
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.passiveConstruction, for: .assistantActionInterpreter) == 1)
        #expect(snapshot.count(.attempted, for: .assistantActionInterpreter) == attempts)
        #expect(snapshot.count(.denied, for: .assistantActionInterpreter) == attempts)
        #expect(snapshot.count(.factoryEvaluated, for: .assistantActionInterpreter) == 0)
        #expect(snapshot.count(.apiEntered, for: .assistantActionInterpreter) == 0)
    }
}
