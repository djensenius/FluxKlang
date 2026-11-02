import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantCredentialIsolationTests {
    enum Operation: CaseIterable, Sendable {
        case read, write, delete
    }

    @Test(arguments: Operation.allCases)
    func concreteOperationsAreDeniedBeforeQueryConstruction(_ operation: Operation) throws {
        let audit = ProductionAccessAudit()
        try #require(AppPersistence.isTesting)
        let credentials = KeychainAssistantCredentialStore(mirroring: audit)
        expectAudit(audit, attempts: 0, constructions: 1)

        for attempt in 1...(operation == .delete ? 2 : 1) {
            switch operation {
            case .read:
                #expect(credentials.value(for: "synthetic-account") == nil)
            case .write:
                #expect(throws: AssistantCredentialError.isolationDenied) {
                    try credentials.setValue("synthetic-value", for: "synthetic-account")
                }
            case .delete:
                #expect(throws: AssistantCredentialError.isolationDenied) {
                    try credentials.removeValue(for: "synthetic-account")
                }
            }
            expectAudit(audit, attempts: UInt64(attempt), constructions: 1)
        }
    }

    @Test(arguments: [true, false])
    func explicitConcreteSettingsInjectionReportsUnavailableCredentials(save: Bool) throws {
        let suite = "AssistantCredentialIsolationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let audit = ProductionAccessAudit()
        try #require(AppPersistence.isTesting)
        let credentials = KeychainAssistantCredentialStore(mirroring: audit)
        let settings = AssistantProviderSettings(defaults: defaults, credentials: credentials)
        #expect(!settings.hasCopilotToken)
        #expect(settings.credentialError == nil)
        expectAudit(audit, attempts: 1, constructions: 1)

        if save {
            settings.saveCopilotToken("synthetic-value")
        } else {
            settings.removeCopilotToken()
        }
        #expect(!settings.hasCopilotToken)
        #expect(settings.credentialError != nil)
        expectAudit(audit, attempts: 2, constructions: 1)
        #expect(settings.copilotConfiguration() == nil)
        expectAudit(audit, attempts: 3, constructions: 1)
    }

    @Test(arguments: [true, false])
    func productionMakerIsLazyOrDeniedAndReturnsFreshMemory(selectIsolated: Bool) throws {
        var previous: MemoryAssistantCredentialStore?
        for _ in 0..<2 {
            let audit = ProductionAccessAudit()
            let selected: any AssistantCredentialStore
            if selectIsolated {
                try #require(AppPersistence.isTesting)
                selected = AssistantCredentialStores.select(
                    isTesting: AppPersistence.isTesting,
                    production: AssistantCredentialStores.makeProduction(mirroring: audit))
            } else {
                try #require(AppPersistence.isTesting)
                selected = AssistantCredentialStores.makeProduction(mirroring: audit)
            }
            let memory = try #require(selected as? MemoryAssistantCredentialStore)
            #expect(memory !== previous)
            #expect(memory.value(for: "synthetic-account") == nil)
            memory.setValue("synthetic-value", for: "synthetic-account")
            #expect(memory.value(for: "synthetic-account") == "synthetic-value")
            expectAudit(audit, attempts: selectIsolated ? 0 : 1, constructions: 0)
            previous = memory
        }
    }

    // Local mirrors check these paths only; they cannot prove shared callsite accounting.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64, constructions: UInt64) {
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .credentialStore) == attempts)
        #expect(snapshot.count(.denied, for: .credentialStore) == attempts)
        #expect(snapshot.count(.passiveConstruction, for: .credentialStore) == constructions)
        #expect(snapshot.count(.factoryEvaluated, for: .credentialStore) == 0)
        #expect(snapshot.count(.apiEntered, for: .credentialStore) == 0)
    }
}
