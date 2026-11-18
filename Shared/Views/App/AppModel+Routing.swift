import CoreGraphics

extension AppModel {
    /// Applies the active environment's canvas wiring to the WING.
    func applyChainRouting() async {
        await wing.apply(environments.chainWingSettings())
    }

    /// The WING settings implied by the active environment: its effects' send/
    /// return routing (resolved against the current channel rig) plus the surround
    /// sends for any voices placed in space. Switching environments and pressing
    /// Apply pushes both, so a setup's spatial placement is recalled too.
    func environmentSettings() -> [WingSetting] {
        EffectRouting.settings(
            for: effectsWithEffectiveConnections(),
            assignments: Equipment.channelAssignments(from: equipment.items)
        ) + environmentSpatialSettings()
    }

    private func effectsWithEffectiveConnections() -> [Effect] {
        let resolver = StudioPhysicalResolver(
            connections: studioConnectionsForCurrentWing().effectiveHome,
            equipment: equipment.items
        )
        return environments.activeEffects.map { effect in
            let jacks = resolver.effectJacks(effect)
            guard jacks.issues.isEmpty else { return effect }
            var resolved = effect
            resolved.sendOutputs = jacks.inputJacks
                .filter { $0.bank == .local }
                .map(\.index)
            resolved.returnInputs = jacks.outputJacks
            return resolved
        }
    }

    /// The surround bus sends for every placed voice of the active environment.
    /// Purely additive — it never touches the main, so placement coexists with
    /// the dry/return mix the effects feed to the main.
    func environmentSpatialSettings() -> [WingSetting] {
        let speakers = spatial.array.speakers
        return placedVoices()
            .filter(\.isPlaced)
            .compactMap { $0.voice.spatialSource(position: $0.position, width: $0.width) }
            .flatMap { SpatialRouting.settings(for: $0, speakers: speakers) }
    }

    /// Applies the active environment's implied send/return routing to the WING.
    func applyEnvironment() async {
        await wing.apply(environmentSettings())
    }

    /// Semantic studio routing plan for the active environment's new canvas.
    func studioRoutingPlan() -> StudioRoutingPlan {
        StudioRoutingPlanner.plan(
            for: environments.activeStudioGraph,
            endpoints: environments.activeStudioEndpoints
        )
    }

    /// WING resource plan for generated endpoint/stem controls.
    func studioResourcePlan() -> StudioResourcePlan {
        StudioResourceAllocator.allocateEndpoints(
            for: studioRoutingPlan(),
            effects: environments.activeEffects,
            speakers: spatial.array.speakers
        )
    }

    /// Compiles the active semantic studio canvas into concrete WING settings.
    func studioCompiledRouting() -> StudioCompiledRouting {
        studioCompiledRouting(connections: studioConnectionsForCurrentWing())
    }

    func studioCompiledRouting(connections: GlobalStudioConnections) -> StudioCompiledRouting {
        StudioSignalCompiler.compile(StudioCompilationInput(
            graph: environments.activeStudioGraph,
            endpoints: environments.activeStudioEndpoints,
            effects: environments.activeEffects,
            connections: connections,
            equipment: equipment.items,
            speakers: spatial.array.speakers
        ))
    }

    /// The placeable voices of the active environment, derived from its routing
    /// graph (dry sources plus shared effect returns).
    func environmentVoices() -> [EnvironmentVoice] {
        guard let environment = environments.active else { return [] }
        return EnvironmentVoices.voices(
            for: environment,
            assignments: Equipment.channelAssignments(from: equipment.items)
        )
    }

    /// The active environment's voices paired with their saved spatial placement.
    /// Unplaced voices sit at the centre and are flagged so they don't yet emit
    /// surround sends.
    func placedVoices() -> [PlacedVoice] {
        guard let environment = environments.active else { return [] }
        return environmentVoices().map { voice in
            let placement = environment.placements[voice.id]
            return PlacedVoice(
                voice: voice,
                position: placement?.position ?? CGPoint(x: 0.5, y: 0.5),
                width: placement?.width ?? 0.5,
                isPlaced: placement != nil
            )
        }
    }

    /// Recalls a preset by applying its settings to the WING.
    func recall(_ preset: Preset) async {
        await wing.apply(preset.settings)
    }

    /// Recalls a routing snapshot, re-patching the whole input/output patchbay.
    func recallRoutingSnapshot(_ snapshot: Preset) async {
        await wing.apply(snapshot.settings)
    }

    /// Captures the current patchbay (channel input patches + physical output
    /// source patches) into a named routing snapshot for instant recall.
    func saveRoutingSnapshot(named name: String) {
        let settings = wing.snapshot(of: routingSnapshotAddresses())
        routingSnapshots.add(Preset(name: name, settings: settings))
    }

    /// Addresses captured into a routing snapshot: every channel's input source
    /// (group + index) and every physical output socket's source (group + index).
    /// Routing only — deliberately excludes faders, mutes and sends so a snapshot
    /// recalls the patch without disturbing the mix.
    private func routingSnapshotAddresses() -> [String] {
        var addresses: [String] = []
        for channel in 1...WingNodeKind.channel.count {
            addresses.append(WingAddress.channelSourceGroup(channel))
            addresses.append(WingAddress.channelSourceIndex(channel))
        }
        for output in 1...WingAddress.localOutputCount {
            addresses.append(WingAddress.outputSourceGroup(output))
            addresses.append(WingAddress.outputSourceIndex(output))
        }
        return addresses
    }

    /// Captures the current mixer + routing state into a named preset.
    func savePreset(named name: String) {
        let settings = wing.snapshot(of: snapshotAddresses())
        presets.add(Preset(name: name, settings: settings))
    }

    /// Addresses captured into a preset snapshot: every fader-strip level and
    /// mute, plus channel input patches, main assignments and bus sends.
    private func snapshotAddresses() -> [String] {
        var addresses: [String] = []
        for strip in faderLayout.layout.strips {
            addresses.append(WingAddress.fader(strip.node.kind, strip.node.index))
            addresses.append(WingAddress.mute(strip.node.kind, strip.node.index))
            if let right = strip.rightNode {
                addresses.append(WingAddress.fader(right.kind, right.index))
                addresses.append(WingAddress.mute(right.kind, right.index))
            }
        }
        for channel in 1...WingNodeKind.channel.count {
            addresses.append(WingAddress.channelSourceGroup(channel))
            addresses.append(WingAddress.channelSourceIndex(channel))
            for main in 1...WingNodeKind.main.count {
                addresses.append(WingAddress.mainOn(.channel, channel, toMain: main))
            }
            for bus in 1...WingNodeKind.bus.count {
                addresses.append(WingAddress.sendOn(.channel, channel, toBus: bus))
                addresses.append(WingAddress.sendLevel(.channel, channel, toBus: bus))
            }
        }
        return addresses
    }
}
