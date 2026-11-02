import Foundation

extension AppModel {
    /// Sequentially joins each owner's scheduled saves at its own capture point.
    /// Capture times differ; this is not an atomic snapshot, a future-producer
    /// barrier, or a durable-save acknowledgement.
    func awaitDomainScheduledSaveSnapshots() async {
        await faderLayout.awaitScheduledSavesSnapshot()
        await equipment.awaitScheduledSavesSnapshot()
        await environments.awaitScheduledSavesSnapshot()
        await presets.awaitScheduledSavesSnapshot()
        await routingSnapshots.awaitScheduledSavesSnapshot()
        await spatial.awaitScheduledSavesSnapshot()
    }
}

extension AppModel {
    private static var completedSharedCheckpoint: ProductionAccessAudit.Checkpoint?
    #if DEBUG
    private static var completedSharedEnvironment: [String: String]?
    private static var firstUIConstructionObservation: UIStartupObservation.Construction?
    private static var firstUIRootWorkObservation: UIStartupObservation.RootWork?
    #endif
    private static let sharedConstruction = {
        #if DEBUG
        let environment = UIStartupObservation.captureEnvironment()
        #endif
        let construction = ProductionAccessAudit.shared.captureConstruction { AppModel() }
        completedSharedCheckpoint = construction.checkpoint
        #if DEBUG
        completedSharedEnvironment = environment
        #endif
        return construction
    }()

    /// The process-wide model used by the app scenes and by App Intents, so a
    /// Shortcut/Siri action drives the same controller and stores as the UI.
    static var shared: AppModel { sharedConstruction.value }
    static var sharedConstructionCheckpoint: ProductionAccessAudit.Checkpoint { sharedConstruction.checkpoint }

    /// Observes completed synchronous construction without initializing the shared model.
    static var completedSharedConstructionCheckpoint: ProductionAccessAudit.Checkpoint? {
        completedSharedCheckpoint
    }

    /// An app model whose controller is a populated demo, for SwiftUI previews.
    static func preview() -> AppModel {
        AppModel(wing: .preview())
    }

    #if DEBUG
    static func captureUIConstructionObservation() -> UIStartupObservation.Construction {
        if let observation = firstUIConstructionObservation { return observation }
        let checkpoint = completedSharedConstructionCheckpoint
        let observation = UIStartupObservation.Construction(
            environment: completedSharedEnvironment,
            checkpointPresent: checkpoint != nil,
            operationCount: ProductionAccessAudit.Operation.allCases.count,
            before: checkpoint.map { UIStartupObservation.counts($0.before) },
            after: checkpoint.map { UIStartupObservation.counts($0.after) }
        )
        // Cache the observation itself, including absence, across root recreation.
        firstUIConstructionObservation = observation
        return observation
    }

    static func captureUIRootWorkObservation() -> UIStartupObservation.RootWork {
        if let observation = firstUIRootWorkObservation { return observation }
        let observation = UIStartupObservation.RootWork(
            cancelled: Task.isCancelled,
            counts: UIStartupObservation.counts(ProductionAccessAudit.shared.snapshot())
        )
        firstUIRootWorkObservation = observation
        return observation
    }
    #endif
}

#if DEBUG
struct UIStartupObservation: Encodable {
    struct Counts: Encodable {
        let operation: Int
        let factoryEvaluated: UInt64
        let apiEntered: UInt64
    }

    struct Construction: Encodable {
        let environment: [String: String]?
        let checkpointPresent: Bool
        let operationCount: Int
        let before: [Counts]?
        let after: [Counts]?
    }

    struct RootWork: Encodable {
        let cancelled: Bool
        let counts: [Counts]
    }

    let construction: Construction
    // Only the root's awaited load/configure calls returned, not all scheduled work.
    let rootAwaitedWork: RootWork?

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "encoding-failed" }
        return String(data: data, encoding: .utf8) ?? "encoding-failed"
    }

    static func captureEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let keys = [
            "FLUXKLANG_ISOLATED_TESTING",
            "FLUXKLANG_QUALIFY_APPLE_ROUTING",
            "FLUXKLANG_RUN_APPLE_MODEL_TESTS"
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            let value: String
            switch environment[key] {
            case .some(let literal) where literal == "0" || literal == "1": value = literal
            case .none: value = "missing"
            default: value = "invalid"
            }
            return (key, value)
        })
    }

    static func counts(_ snapshot: ProductionAccessAudit.Snapshot) -> [Counts] {
        ProductionAccessAudit.Operation.allCases.map { operation in
            Counts(
                operation: operation.rawValue,
                factoryEvaluated: snapshot.count(.factoryEvaluated, for: operation),
                apiEntered: snapshot.count(.apiEntered, for: operation)
            )
        }
    }
}
#endif
