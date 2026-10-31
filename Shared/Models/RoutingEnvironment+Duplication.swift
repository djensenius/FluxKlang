//
//  RoutingEnvironment+Duplication.swift
//  FluxKlang
//
//  Duplicating an environment gives every environment-local object a fresh
//  identity and rewrites every reference to it, while references to shared
//  identities (the equipment library, WING/console coordinates, Home wiring
//  evidence) are preserved so the copy still describes the same physical rig.
//
//  Decision table (reference → treatment):
//
//  | Reference                                        | Scope  | Treatment          |
//  |--------------------------------------------------|--------|--------------------|
//  | RoutingEnvironment.id                            | local  | fresh              |
//  | Effect.id                                        | local  | fresh              |
//  | Effect.destinationEffectID                       | local  | remap (unknown→nil)|
//  | Effect.equipmentID / sourceInstruments           | shared | preserve           |
//  | placements key "return:<Effect.ID>"              | local  | remap              |
//  | placements key "source:<Equipment.ID>"           | shared | preserve           |
//  | ChainNode.id / ChainEdge.id                      | local  | fresh              |
//  | ChainPortRef.nodeID                              | local  | remap              |
//  | ChainNodeKind (.equipment / WING endpoints)      | shared | preserve           |
//  | StudioNode.id / StudioEdge.id                    | local  | fresh              |
//  | StudioPortRef.nodeID                             | local  | remap              |
//  | StudioNodeKind.effect(Effect.ID)                 | local  | remap              |
//  | StudioNodeKind.endpoint(StudioEndpoint.ID)       | local  | remap              |
//  | StudioNodeKind.instrument(Equipment.ID)          | shared | preserve           |
//  | StudioNodeKind.liveChannel (console evidence)    | shared | preserve           |
//  | StudioEndpoint.id                                | local  | fresh              |
//  | StudioEndpoint.outputReferences/outputConnectors | shared | preserve           |
//  | StudioDeviceProfile.id / StudioPortPatch.id      | local  | fresh              |
//  | StudioDeviceRef.effect(Effect.ID)                | local  | remap              |
//  | StudioDeviceRef.equipment(Equipment.ID)          | shared | preserve           |
//
//  Local IDs that do not resolve inside the original (already dangling) are
//  carried over verbatim, except a serial-chain destination, which falls back
//  to the main as before. Global stores — Home wiring, temporary moves,
//  presets, fader layout — key on equipment/WING identity and are not
//  environment-scoped, so they are untouched. Persisted assistant drafts
//  (assistant-pending-studio-draft.json) are bound to the source environment
//  ID and rejected for the copy (StudioWiringAdvisor.swift:182).
//
//  An owned identity (effect, endpoint, node) is always in the remap; the
//  `?? UUID()` fallbacks are unreachable and only guarantee that an owned ID
//  is never reused. Reference fallbacks (`?? id`) implement the verbatim
//  carry-over of already-dangling references described above.
//

import Foundation

/// Fresh identities for every environment-local object of one environment.
struct EnvironmentIdentityRemap: Sendable {
    var effects: [Effect.ID: Effect.ID]
    var endpoints: [StudioEndpoint.ID: StudioEndpoint.ID]
    var chainNodes: [ChainNode.ID: ChainNode.ID]
    var studioNodes: [StudioNode.ID: StudioNode.ID]

    init(for environment: RoutingEnvironment) {
        effects = Self.fresh(environment.effects.map(\.id))
        endpoints = Self.fresh(environment.studioEndpoints.map(\.id))
        chainNodes = Self.fresh(environment.graph.nodes.map(\.id))
        studioNodes = Self.fresh(environment.studioGraph.nodes.map(\.id))
    }

    private static func fresh(_ ids: [UUID]) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for id in ids where result[id] == nil {
            result[id] = UUID()
        }
        return result
    }

    func effect(_ effect: Effect) -> Effect {
        var copy = effect
        copy.id = effects[effect.id] ?? UUID()
        copy.destinationEffectID = effect.destinationEffectID.flatMap { effects[$0] }
        return copy
    }

    func placements(_ placements: [String: VoicePlacement]) -> [String: VoicePlacement] {
        var result: [String: VoicePlacement] = [:]
        for (key, placement) in placements {
            result[EnvironmentVoice.remap(voiceID: key, effects: effects)] = placement
        }
        return result
    }

    func chainGraph(_ graph: ChainGraph) -> ChainGraph {
        let nodes = graph.nodes.map { node -> ChainNode in
            var copy = node
            copy.id = chainNodes[node.id] ?? UUID()
            return copy
        }
        let edges = graph.edges.map { edge -> ChainEdge in
            var from = edge.from
            var to = edge.to
            from.nodeID = chainNodes[from.nodeID] ?? from.nodeID
            to.nodeID = chainNodes[to.nodeID] ?? to.nodeID
            return ChainEdge(from: from, to: to)
        }
        return ChainGraph(nodes: nodes, edges: edges)
    }

    func studioGraph(_ graph: StudioGraph) -> StudioGraph {
        var copy = graph
        copy.nodes = graph.nodes.map { node -> StudioNode in
            var remapped = node
            remapped.id = studioNodes[node.id] ?? UUID()
            remapped.kind = studioNodeKind(node.kind)
            return remapped
        }
        copy.edges = graph.edges.map { edge -> StudioEdge in
            var from = edge.from
            var to = edge.to
            from.nodeID = studioNodes[from.nodeID] ?? from.nodeID
            to.nodeID = studioNodes[to.nodeID] ?? to.nodeID
            return StudioEdge(from: from, to: to)
        }
        return copy
    }

    func studioNodeKind(_ kind: StudioNodeKind) -> StudioNodeKind {
        switch kind {
        case .effect(let id): .effect(effects[id] ?? id)
        case .endpoint(let id): .endpoint(endpoints[id] ?? id)
        case .instrument, .liveChannel: kind
        }
    }

    func endpoint(_ endpoint: StudioEndpoint) -> StudioEndpoint {
        var copy = endpoint
        copy.id = endpoints[endpoint.id] ?? UUID()
        return copy
    }

    func studioSetup(_ setup: StudioSetup) -> StudioSetup {
        StudioSetup(devices: setup.devices.map { profile in
            let device = deviceRef(profile.device)
            return StudioDeviceProfile(
                device: device,
                name: profile.name,
                role: profile.role,
                patches: profile.patches.map { patch in
                    StudioPortPatch(
                        device: deviceRef(patch.device),
                        side: patch.side,
                        port: patch.port,
                        connector: patch.connector
                    )
                }
            )
        })
    }

    func deviceRef(_ device: StudioDeviceRef) -> StudioDeviceRef {
        switch device {
        case .effect(let id): .effect(effects[id] ?? id)
        case .equipment: device
        }
    }
}

extension RoutingEnvironment {
    /// A deep copy under a new identity. Every environment-local identity
    /// (effects, canvas nodes/edges, studio endpoints, legacy setup profiles)
    /// is fresh and every reference to it is rewritten through
    /// `EnvironmentIdentityRemap`, so the copy never points back at the
    /// original; shared equipment and WING identities are preserved.
    func duplicated(named newName: String) -> RoutingEnvironment {
        let remap = EnvironmentIdentityRemap(for: self)
        return RoutingEnvironment(
            name: newName,
            effects: effects.map(remap.effect),
            placements: remap.placements(placements),
            graph: remap.chainGraph(graph),
            studioGraph: remap.studioGraph(studioGraph),
            studioEndpoints: studioEndpoints.map(remap.endpoint),
            studioSetup: remap.studioSetup(studioSetup)
        )
    }
}
