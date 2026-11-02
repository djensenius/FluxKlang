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
