import Foundation
import Testing
@testable import FluxKlang

struct CloudStoreIsolationTests {
    @Test func defaultConstructionIsDeniedBeforeBackendSelection() throws {
        let audit = ProductionAccessAudit()
        try requireIsolatedProcess()

        _ = UbiquitousCloudStore(mirroring: audit)

        expectAudit(audit, attempts: 1)
    }

    @Test func directReadIsUnavailable() throws {
        let audit = ProductionAccessAudit()
        try requireIsolatedProcess()
        let store = UbiquitousCloudStore(mirroring: audit)
        expectAudit(audit, attempts: 1)

        try requireIsolatedProcess()
        let unavailable = store.data(forKey: "synthetic-key") == nil

        #expect(unavailable)
        expectAudit(audit, attempts: 2)
    }

    @Test func deniedWriteLeavesReadUnavailable() throws {
        let audit = ProductionAccessAudit()
        try requireIsolatedProcess()
        let store = UbiquitousCloudStore(mirroring: audit)
        expectAudit(audit, attempts: 1)

        try requireIsolatedProcess()
        store.setData(Data("synthetic-value".utf8), forKey: "synthetic-key")
        expectAudit(audit, attempts: 2)

        try requireIsolatedProcess()
        let unavailable = store.data(forKey: "synthetic-key") == nil
        // This denied read is not an independent check of remote persistence.
        #expect(unavailable)
        expectAudit(audit, attempts: 3)
    }

    @Test func repeatedSynchronizationReturnsFalse() throws {
        let audit = ProductionAccessAudit()
        try requireIsolatedProcess()
        let store = UbiquitousCloudStore(mirroring: audit)
        expectAudit(audit, attempts: 1)

        for attempt in 1...2 {
            try requireIsolatedProcess()
            let synchronized = store.synchronize()

            #expect(!synchronized)
            expectAudit(audit, attempts: UInt64(attempt + 1))
        }
    }

    private func requireIsolatedProcess() throws {
        let environment = ProcessInfo.processInfo.environment
        let isTesting = AppPersistence.isTesting
        let modelFlagDisabled = environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] != "1"
        let routingFlagDisabled = environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] != "1"
        try #require(isTesting, "Cloud boundary tests require process-selected isolation")
        try #require(modelFlagDisabled, "Model qualification must be disabled")
        try #require(routingFlagDisabled, "Routing qualification must be disabled")
    }

    // Local mirrors describe these denied calls only, not global accounting or all cloud effects.
    private func expectAudit(_ audit: ProductionAccessAudit, attempts: UInt64) {
        let snapshot = audit.snapshot()
        let attempted = snapshot.count(.attempted, for: .ubiquitousCloudStore)
        let denied = snapshot.count(.denied, for: .ubiquitousCloudStore)
        let factories = snapshot.count(.factoryEvaluated, for: .ubiquitousCloudStore)
        let passive = snapshot.count(.passiveConstruction, for: .ubiquitousCloudStore)
        let apiEntries = snapshot.count(.apiEntered, for: .ubiquitousCloudStore)
        #expect(attempted == attempts)
        #expect(denied == attempts)
        #expect(factories == 0)
        #expect(passive == 0)
        #expect(apiEntries == 0)
    }
}
