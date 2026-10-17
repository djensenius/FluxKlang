extension AppModel {
    /// Applies every valid Studio branch after confirming generated endpoint
    /// buses are muted at their safe starting level.
    func applyStudio() async -> WingApplyVerification {
        let compiled = studioCompiledRouting()
        let safetyAddresses = Set(compiled.resourcePlan.allocations.flatMap { allocation in
            [allocation.controlNode, allocation.rightControlNode].compactMap { node in
                node.map {
                    [
                        WingAddress.fader($0.kind, $0.index),
                        WingAddress.mute($0.kind, $0.index)
                    ]
                }
            }.flatMap { $0 }
        })
        let safetySettings = compiled.settings.filter { safetyAddresses.contains($0.address) }
        return await wing.applyAndVerify(compiled.settings, safetySettings: safetySettings)
    }
}
