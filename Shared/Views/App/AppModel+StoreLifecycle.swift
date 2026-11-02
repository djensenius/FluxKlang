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
    private static let sharedConstruction = {
        let construction = ProductionAccessAudit.shared.captureConstruction { AppModel() }
        completedSharedCheckpoint = construction.checkpoint
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
}
