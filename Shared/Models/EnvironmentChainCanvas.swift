//
//  EnvironmentChainCanvas.swift
//  FluxKlang
//
//  The pure model behind authoring an environment's effects on the chain canvas.
//  The same drag-and-drop surface that wires raw WING endpoints also shows the
//  environment's effects as nodes: instrument sources (left) feed effect nodes
//  (middle) whose returns land on Main (right). These nodes are *derived* from
//  the environment's `[Effect]` rather than stored in the `ChainGraph`, so the
//  list editor and the canvas always agree — wiring on the canvas just edits the
//  same effects the list does.
//
//  Everything here is pure (no stores, no disk), so the reconciliation rules —
//  which wire means "add a source", "chain into another effect", or "return to
//  Main" — are unit-tested directly against value types.
//

import CoreGraphics
import Foundation

enum EnvironmentChainCanvas {
    /// Stable id of the single Main node, so its canvas position survives renders.
    static let mainNodeID = UUID(uuidString: "0000FEED-0000-0000-0000-000000000001")!

    // MARK: - Layout keys

    /// Layout key for the Main node.
    static let mainKey = "main"
    /// Layout key for an effect node.
    static func effectKey(_ id: Effect.ID) -> String { "effect:" + id.uuidString }
    /// Layout key for an instrument-source node.
    static func sourceKey(_ id: Equipment.ID) -> String { "source:" + id.uuidString }

    /// The layout key for a derived node kind (nil for free-form patchbay nodes).
    static func layoutKey(for kind: ChainNodeKind) -> String? {
        switch kind {
        case .effect(let id): return effectKey(id)
        case .effectSource(let id): return sourceKey(id)
        case .effectMain: return mainKey
        default: return nil
        }
    }

    /// Rewrites an effect-node layout key onto a new effect id using `remap`;
    /// source and Main keys (and anything unrecognised) pass through unchanged.
    /// Used when an environment is duplicated and its effects get fresh ids.
    static func remap(nodeKey: String, effects remap: [Effect.ID: Effect.ID]) -> String {
        let prefix = "effect:"
        guard nodeKey.hasPrefix(prefix),
              let oldID = UUID(uuidString: String(nodeKey.dropFirst(prefix.count))),
              let newID = remap[oldID] else {
            return nodeKey
        }
        return effectKey(newID)
    }

    // MARK: - Default layout

    static func defaultSourcePosition(index: Int) -> CGPoint {
        CGPoint(x: 200, y: 150 + CGFloat(index) * 150)
    }

    static func defaultEffectPosition(index: Int) -> CGPoint {
        CGPoint(x: 580, y: 150 + CGFloat(index) * 150)
    }

    static let defaultMainPosition = CGPoint(x: 960, y: 220)

    // MARK: - Derived nodes

    /// The instrument ids shown as source nodes: every instrument feeding an
    /// effect, plus any the user has dropped on the canvas (tracked by a layout
    /// entry) but not yet wired up.
    static func sourceInstruments(effects: [Effect], layout: [String: CGPoint]) -> [Equipment.ID] {
        var ids = Set(effects.flatMap { $0.sourceInstruments })
        for key in layout.keys where key.hasPrefix("source:") {
            if let id = UUID(uuidString: String(key.dropFirst("source:".count))) {
                ids.insert(id)
            }
        }
        return Array(ids)
    }

    /// The derived nodes for the effect overlay: one per source instrument, one
    /// per effect, and a single Main when there is anything to return to it.
    /// Source order follows the equipment library so the default layout is stable.
    static func nodes(
        effects: [Effect],
        layout: [String: CGPoint],
        equipment: [Equipment]
    ) -> [ChainNode] {
        var nodes: [ChainNode] = []
        let libraryOrder = Dictionary(
            equipment.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let nameByID = Dictionary(equipment.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        let sources = sourceInstruments(effects: effects, layout: layout)
            .sorted { (libraryOrder[$0] ?? .max, $0.uuidString) < (libraryOrder[$1] ?? .max, $1.uuidString) }
        for (index, id) in sources.enumerated() {
            nodes.append(ChainNode(
                id: id,
                kind: .effectSource(id),
                title: nameByID[id] ?? "Instrument",
                position: layout[sourceKey(id)] ?? defaultSourcePosition(index: index)
            ))
        }

        for (index, effect) in effects.enumerated() {
            nodes.append(ChainNode(
                id: effect.id,
                kind: .effect(effect.id),
                title: effect.name,
                position: layout[effectKey(effect.id)] ?? defaultEffectPosition(index: index)
            ))
        }

        if !effects.isEmpty || layout[mainKey] != nil {
            nodes.append(ChainNode(
                id: mainNodeID,
                kind: .effectMain,
                title: "Main",
                position: layout[mainKey] ?? defaultMainPosition
            ))
        }
        return nodes
    }

    // MARK: - Derived edges

    /// What an overlay wire means, so deleting it maps back to an effect edit.
    enum EdgeKind: Hashable, Sendable {
        /// An instrument feeds an effect.
        case source(instrument: Equipment.ID, effect: Effect.ID)
        /// An effect's output is chained into another effect.
        case chain(from: Effect.ID, to: Effect.ID)
        /// An effect's output returns to the Main.
        case toMain(effect: Effect.ID)
    }

    /// A wire in the effect overlay, with a stable id for diffing and a flag for
    /// whether deleting it is meaningful (returning to Main is the default state,
    /// so those wires aren't deletable).
    struct DerivedEdge: Identifiable, Hashable, Sendable {
        var id: String
        var from: ChainPortRef
        var to: ChainPortRef
        var kind: EdgeKind
        var isDeletable: Bool
    }

    /// The overlay wires implied by the effects: source → effect, effect → effect
    /// (serial chains), and effect → Main (parallel returns). Only sources that
    /// have a node on the canvas are wired, so the picture matches what's shown.
    static func edges(effects: [Effect], layout: [String: CGPoint]) -> [DerivedEdge] {
        let shownSources = Set(sourceInstruments(effects: effects, layout: layout))
        let effectIDs = Set(effects.map { $0.id })
        var edges: [DerivedEdge] = []

        for effect in effects {
            for instrument in effect.sourceInstruments where shownSources.contains(instrument) {
                edges.append(DerivedEdge(
                    id: "src:\(instrument.uuidString)->eff:\(effect.id.uuidString)",
                    from: ChainPortRef(nodeID: instrument, side: .output, port: 0),
                    to: ChainPortRef(nodeID: effect.id, side: .input, port: 0),
                    kind: .source(instrument: instrument, effect: effect.id),
                    isDeletable: true
                ))
            }

            if let destination = effect.destinationEffectID, effectIDs.contains(destination) {
                edges.append(DerivedEdge(
                    id: "eff:\(effect.id.uuidString)->eff:\(destination.uuidString)",
                    from: ChainPortRef(nodeID: effect.id, side: .output, port: 0),
                    to: ChainPortRef(nodeID: destination, side: .input, port: 0),
                    kind: .chain(from: effect.id, to: destination),
                    isDeletable: true
                ))
            } else {
                edges.append(DerivedEdge(
                    id: "eff:\(effect.id.uuidString)->main",
                    from: ChainPortRef(nodeID: effect.id, side: .output, port: 0),
                    to: ChainPortRef(nodeID: mainNodeID, side: .input, port: 0),
                    kind: .toMain(effect: effect.id),
                    isDeletable: false
                ))
            }
        }
        return edges
    }

    // MARK: - Allocation-aware ports

    /// The input/output labels for a derived node, surfacing the auto-allocated
    /// bus (an effect's input) and return channel (an effect's output) and an
    /// instrument's WING channels — so the plumbing is visible right on the wires.
    static func ports(
        for kind: ChainNodeKind,
        effects: [Effect],
        allocations: [Effect.ID: EffectRouting.Allocation],
        assignments: [Equipment.ChannelAssignment]
    ) -> ChainPorts {
        switch kind {
        case .effectSource(let id):
            let channels = assignments.first { $0.equipment.id == id }
                .map { [$0.leftChannel] + ($0.rightChannel.map { [$0] } ?? []) } ?? []
            return ChainPorts(inputs: [], outputs: [channelLabel(prefix: "Ch", channels)])
        case .effect(let id):
            let allocation = allocations[id]
            return ChainPorts(
                inputs: [channelLabel(prefix: "Bus", allocation?.buses ?? [])],
                outputs: [channelLabel(prefix: "Rtn", allocation?.returnChannels ?? [])]
            )
        case .effectMain:
            return ChainPorts(inputs: ["Returns"], outputs: [])
        default:
            return ChainPorts(inputs: [], outputs: [])
        }
    }

    private static func channelLabel(prefix: String, _ values: [Int]) -> String {
        guard !values.isEmpty else { return "\(prefix) —" }
        return "\(prefix) " + values.map(String.init).joined(separator: "/")
    }

    // MARK: - Reconciliation

    /// The result of dropping a wire from one node onto another.
    enum ConnectOutcome: Equatable {
        /// The wire edits the effects; use this new list.
        case effects([Effect])
        /// The wire isn't part of the effect overlay — let the free-form patchbay
        /// handle it (e.g. equipment → WING channel).
        case notEffectEdge
        /// The wire is rejected (e.g. into an instrument, or a cycle).
        case rejected
    }

    /// Reconciles a dropped wire into a new `[Effect]`. Only wires *between* effect
    /// nodes count: source → effect adds a source, effect → effect forms a serial
    /// chain (unless it would loop), and effect → Main returns it in parallel.
    /// Mixed wires (one effect node, one free-form node) are rejected so the two
    /// halves of the canvas don't get cross-wired by accident.
    static func connect(
        from origin: ChainNodeKind,
        to destination: ChainNodeKind,
        effects: [Effect]
    ) -> ConnectOutcome {
        guard origin.isEffectDomain || destination.isEffectDomain else { return .notEffectEdge }
        guard origin.isEffectDomain && destination.isEffectDomain else { return .rejected }

        switch (origin, destination) {
        case let (.effectSource(instrument), .effect(effectID)):
            return setSource(instrument, on: effectID, isOn: true, effects: effects)
        case let (.effect(fromID), .effect(toID)):
            guard fromID != toID, !wouldCycle(from: fromID, into: toID, effects: effects) else { return .rejected }
            return setDestination(toID, on: fromID, effects: effects)
        case let (.effect(fromID), .effectMain):
            return setDestination(nil, on: fromID, effects: effects)
        default:
            return .rejected
        }
    }

    /// Undoes an overlay wire: a source wire drops that source, a chain wire
    /// reverts the effect to the Main. Main wires aren't deletable, so they're
    /// returned unchanged.
    static func disconnect(_ kind: EdgeKind, effects: [Effect]) -> [Effect] {
        switch kind {
        case let .source(instrument, effectID):
            if case let .effects(updated) = setSource(instrument, on: effectID, isOn: false, effects: effects) {
                return updated
            }
            return effects
        case let .chain(fromID, _):
            if case let .effects(updated) = setDestination(nil, on: fromID, effects: effects) {
                return updated
            }
            return effects
        case .toMain:
            return effects
        }
    }

    /// Removes a derived node, cleaning up the effects it touched: deleting an
    /// effect drops it and any chain links pointing at it; deleting a source drops
    /// it from every effect it fed. Removing Main is a no-op (it always exists).
    static func removeNode(_ kind: ChainNodeKind, effects: [Effect]) -> [Effect] {
        switch kind {
        case .effect(let id):
            return effects.compactMap { effect in
                guard effect.id != id else { return nil }
                var copy = effect
                if copy.destinationEffectID == id { copy.destinationEffectID = nil }
                return copy
            }
        case .effectSource(let instrument):
            return effects.map { $0.togglingSource(instrument, false) }
        default:
            return effects
        }
    }

    // MARK: - Helpers

    private static func setSource(
        _ instrument: Equipment.ID,
        on effectID: Effect.ID,
        isOn: Bool,
        effects: [Effect]
    ) -> ConnectOutcome {
        guard effects.contains(where: { $0.id == effectID }) else { return .rejected }
        let updated = effects.map { $0.id == effectID ? $0.togglingSource(instrument, isOn) : $0 }
        return .effects(updated)
    }

    private static func setDestination(
        _ destination: Effect.ID?,
        on effectID: Effect.ID,
        effects: [Effect]
    ) -> ConnectOutcome {
        guard effects.contains(where: { $0.id == effectID }) else { return .rejected }
        let updated = effects.map { effect -> Effect in
            guard effect.id == effectID else { return effect }
            var copy = effect
            copy.destinationEffectID = destination
            return copy
        }
        return .effects(updated)
    }

    /// Whether chaining `from` into `into` would close a loop, i.e. `into` already
    /// feeds back to `from` (directly or transitively).
    static func wouldCycle(from: Effect.ID, into: Effect.ID, effects: [Effect]) -> Bool {
        let byID = Dictionary(effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current: Effect.ID? = into
        var steps = 0
        while let id = current {
            if id == from { return true }
            steps += 1
            if steps > byID.count { return true }
            current = byID[id]?.destinationEffectID
        }
        return false
    }
}
