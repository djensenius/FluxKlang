import Foundation
import Synchronization
import Testing
@testable import FluxKlang

struct CloudObserverIsolationTests {
    @Test func deniedConstructionAndTeardownEnterNoAPIs() throws {
        let environment = ProcessInfo.processInfo.environment
        let isTesting = AppPersistence.isTesting
        let modelFlagDisabled = environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] != "1"
        let routingFlagDisabled = environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] != "1"
        try #require(isTesting, "Cloud boundary tests require process-selected isolation")
        try #require(modelFlagDisabled, "Model qualification must be disabled")
        try #require(routingFlagDisabled, "Routing qualification must be disabled")

        let audit = ProductionAccessAudit()
        let callbacks = CloudObserverCallbackCounter()
        var owner: CloudChangeObserver? = CloudChangeObserver(mirroring: audit) {
            callbacks.increment()
        }
        weak var observer = owner

        withExtendedLifetime(owner) {
            let isAlive = observer != nil
            #expect(isAlive)
            expectDeniedAudit(audit)
            let callbackCount = callbacks.count
            #expect(callbackCount == 0)
        }

        owner = nil
        let isReleased = observer == nil
        #expect(isReleased)
        expectDeniedAudit(audit)
        let callbackCount = callbacks.count
        #expect(callbackCount == 0)
    }

    // Only this denied construction and tokenless teardown, not future callbacks or global effects.
    private func expectDeniedAudit(_ audit: ProductionAccessAudit) {
        let snapshot = audit.snapshot()
        let attempted = snapshot.count(.attempted, for: .cloudChangeObserver)
        let denied = snapshot.count(.denied, for: .cloudChangeObserver)
        let factories = snapshot.count(.factoryEvaluated, for: .cloudChangeObserver)
        let passive = snapshot.count(.passiveConstruction, for: .cloudChangeObserver)
        let apiEntries = snapshot.count(.apiEntered, for: .cloudChangeObserver)
        #expect(attempted == 1)
        #expect(denied == 1)
        #expect(factories == 0)
        #expect(passive == 0)
        #expect(apiEntries == 0)
    }
}

private final class CloudObserverCallbackCounter: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func increment() {
        value.withLock { $0 += 1 }
    }
}
