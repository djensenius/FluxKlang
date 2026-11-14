import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantSpeechIsolationTests {
    @Test func productionFactoryDeniesBeforeSynthesizerConstruction() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()

        _ = AssistantChatController.makeProductionSpeech(mirroring: audit)

        expectAudit(audit, attempts: 1)
    }

    @Test func deniedFactoryCallableRemainsInertOnRepeatedInvocations() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let audit = ProductionAccessAudit()
        let speak = AssistantChatController.makeProductionSpeech(mirroring: audit)
        expectAudit(audit, attempts: 1)

        speak("Synthetic reply one")
        speak("Synthetic reply two")

        expectAudit(audit, attempts: 3)
    }

    // Local mirrors describe these paths only, not shared-global or future-callback coverage.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64) {
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .assistantSpeech) == attempts)
        #expect(snapshot.count(.denied, for: .assistantSpeech) == attempts)
        #expect(snapshot.count(.factoryEvaluated, for: .assistantSpeech) == 0)
        #expect(snapshot.count(.passiveConstruction, for: .assistantSpeech) == 0)
        #expect(snapshot.count(.apiEntered, for: .assistantSpeech) == 0)
    }
}
