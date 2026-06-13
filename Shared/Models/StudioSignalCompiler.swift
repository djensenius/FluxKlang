//
//  StudioSignalCompiler.swift
//  FluxKlang
//
//  Compiles the valid branches of the semantic studio graph into WING settings.
//  This is the bridge from "draw instruments/effects/endpoints" to concrete
//  sends, effect I/O patching, and generated endpoint/stem controls.
//

import Foundation

struct StudioCompileIssue: Identifiable, Hashable, Sendable {
    enum Severity: String, Hashable, Sendable {
        case warning
        case error
    }

    enum Kind: Hashable, Sendable {
        case missingInstrument(StudioNode.ID)
        case missingEffect(StudioNode.ID)
        case missingEndpointAllocation(StudioNode.ID)
        case missingEffectAllocation(Effect.ID)
        case unsupportedEdge(StudioEdge.ID)
    }

    var severity: Severity
    var kind: Kind
    var message: String

    var id: String { "\(severity.rawValue)-\(message)-\(kind)" }
}

struct StudioCompiledRouting: Hashable, Sendable {
    var routingPlan: StudioRoutingPlan
    var resourcePlan: StudioResourcePlan
    var issues: [StudioCompileIssue]
    var settings: [WingSetting]

    var hasErrors: Bool {
        routingPlan.hasErrors || resourcePlan.hasErrors || issues.contains { $0.severity == .error }
    }
}

enum StudioSignalCompiler {
    static func compile(
        graph: StudioGraph,
        endpoints: [StudioEndpoint],
        effects: [Effect],
        assignments: [Equipment.ChannelAssignment],
        speakers: [Speaker]
    ) -> StudioCompiledRouting {
        let routingPlan = StudioRoutingPlanner.plan(for: graph, endpoints: endpoints)
        let resourcePlan = StudioResourceAllocator.allocateEndpoints(
            for: routingPlan,
            effects: effects,
            speakers: speakers
        )
        let context = CompileContext(
            graph: graph,
            effects: effects,
            assignments: assignments,
            routingPlan: routingPlan,
            resourcePlan: resourcePlan
        )
        let compiled = compileValidEdges(context: context)
        return StudioCompiledRouting(
            routingPlan: routingPlan,
            resourcePlan: resourcePlan,
            issues: compiled.issues,
            settings: uniqueSettings(
                StudioResourceAllocator.settings(for: resourcePlan)
                    + compiled.settings
                    + spaceSettings(for: resourcePlan.allocations, speakers: speakers)
            )
        )
    }

    private static func compileValidEdges(
        context: CompileContext
    ) -> (settings: [WingSetting], issues: [StudioCompileIssue]) {
        var settings: [WingSetting] = []
        var issues: [StudioCompileIssue] = []
        var patchedEffects: Set<Effect.ID> = []
        for edge in context.graph.edges {
            guard context.isAppliable(edge) else { continue }
            guard let from = context.node(edge.from.nodeID),
                  let destination = context.node(edge.to.nodeID) else { continue }
            let compiled = compile(edge: edge, from: from, to: destination, context: context)
            settings.append(contentsOf: compiled.settings)
            issues.append(contentsOf: compiled.issues)
            if let effectID = effectID(from.kind), !patchedEffects.contains(effectID) {
                settings.append(contentsOf: effectPatchSettings(effectID: effectID, context: context, issues: &issues))
                patchedEffects.insert(effectID)
            }
            if let effectID = effectID(destination.kind), !patchedEffects.contains(effectID) {
                settings.append(contentsOf: effectPatchSettings(effectID: effectID, context: context, issues: &issues))
                patchedEffects.insert(effectID)
            }
        }
        return (settings, uniqueIssues(issues))
    }

    private static func compile(
        edge: StudioEdge,
        from: StudioNode,
        to destination: StudioNode,
        context: CompileContext
    ) -> (settings: [WingSetting], issues: [StudioCompileIssue]) {
        switch (from.kind, destination.kind) {
        case (.instrument(let instrumentID), .endpoint):
            return routeInstrument(instrumentID, toEndpointNode: destination.id, context: context)
        case (.instrument(let instrumentID), .effect(let effectID)):
            return routeInstrument(instrumentID, toEffect: effectID, context: context)
        case (.effect(let sourceID), .endpoint):
            return routeEffect(sourceID, toEndpointNode: destination.id, context: context)
        case (.effect(let sourceID), .effect(let targetID)):
            return routeEffect(sourceID, toEffect: targetID, context: context)
        default:
            return ([], [.warning(
                .unsupportedEdge(edge.id),
                "\(from.title) cannot be routed to \(destination.title) yet."
            )])
        }
    }

    private static func routeInstrument(
        _ instrumentID: Equipment.ID,
        toEndpointNode endpointNodeID: StudioNode.ID,
        context: CompileContext
    ) -> (settings: [WingSetting], issues: [StudioCompileIssue]) {
        guard let assignment = context.assignmentByInstrument[instrumentID] else {
            return ([], [.error(.missingInstrument(endpointNodeID), "Gear in the patch is not plugged in yet.")])
        }
        guard let endpointBus = context.endpointBus(for: endpointNodeID) else {
            return ([], [.error(.missingEndpointAllocation(endpointNodeID), "A control has no generated mixer path.")])
        }
        return (assignment.channels.flatMap { send(kind: .channel, index: $0, toBus: endpointBus) }, [])
    }

    private static func routeInstrument(
        _ instrumentID: Equipment.ID,
        toEffect effectID: Effect.ID,
        context: CompileContext
    ) -> (settings: [WingSetting], issues: [StudioCompileIssue]) {
        guard let assignment = context.assignmentByInstrument[instrumentID] else {
            return ([], [.error(.missingInstrument(effectID), "Gear feeding another gear card is not plugged in yet.")])
        }
        guard let effect = context.effectByID[effectID],
              let allocation = context.effectAllocations[effectID],
              let busLeft = allocation.buses.first else {
            return ([], [.error(.missingEffectAllocation(effectID), "A gear card has no available mixer path.")])
        }
        let busRight = effect.isStereo ? (allocation.buses.last ?? busLeft) : busLeft
        if effect.isStereo {
            let left = assignment.leftChannel
            let right = assignment.rightChannel ?? assignment.leftChannel
            return (send(kind: .channel, index: left, toBus: busLeft)
                + send(kind: .channel, index: right, toBus: busRight), [])
        }
        return (assignment.channels.flatMap { send(kind: .channel, index: $0, toBus: busLeft) }, [])
    }

    private static func routeEffect(
        _ effectID: Effect.ID,
        toEndpointNode endpointNodeID: StudioNode.ID,
        context: CompileContext
    ) -> (settings: [WingSetting], issues: [StudioCompileIssue]) {
        guard let allocation = context.effectAllocations[effectID], !allocation.returnChannels.isEmpty else {
            return ([], [.error(
                .missingEffectAllocation(effectID),
                "A processed gear branch has no available mixer return."
            )])
        }
        guard let endpointBus = context.endpointBus(for: endpointNodeID) else {
            return ([], [.error(.missingEndpointAllocation(endpointNodeID), "A control has no generated mixer path.")])
        }
        return (allocation.returnChannels.flatMap { send(kind: .channel, index: $0, toBus: endpointBus) }, [])
    }

    private static func routeEffect(
        _ sourceID: Effect.ID,
        toEffect targetID: Effect.ID,
        context: CompileContext
    ) -> (settings: [WingSetting], issues: [StudioCompileIssue]) {
        guard let sourceAllocation = context.effectAllocations[sourceID],
              !sourceAllocation.returnChannels.isEmpty,
              let target = context.effectByID[targetID],
              let targetAllocation = context.effectAllocations[targetID],
              let targetBusLeft = targetAllocation.buses.first else {
            return ([], [.error(.missingEffectAllocation(sourceID), "Connected gear has no available mixer path.")])
        }
        let targetBusRight = target.isStereo ? (targetAllocation.buses.last ?? targetBusLeft) : targetBusLeft
        if target.isStereo {
            let left = sourceAllocation.returnChannels.first
            let right = sourceAllocation.returnChannels.count > 1
                ? sourceAllocation.returnChannels[1]
                : sourceAllocation.returnChannels.first
            return ([left, right].enumerated().flatMap { index, channel -> [WingSetting] in
                guard let channel else { return [] }
                return send(kind: .channel, index: channel, toBus: index == 0 ? targetBusLeft : targetBusRight)
            }, [])
        }
        return (sourceAllocation.returnChannels.flatMap {
            send(kind: .channel, index: $0, toBus: targetBusLeft)
        }, [])
    }

    private static func effectPatchSettings(
        effectID: Effect.ID,
        context: CompileContext,
        issues: inout [StudioCompileIssue]
    ) -> [WingSetting] {
        guard let effect = context.effectByID[effectID] else {
            issues.append(.error(.missingEffect(effectID), "Gear in the patch no longer exists."))
            return []
        }
        guard let allocation = context.effectAllocations[effectID],
              let busLeft = allocation.buses.first else {
            issues.append(.error(.missingEffectAllocation(effectID), "\(effect.name) has no available mixer path."))
            return []
        }
        let busRight = effect.isStereo ? (allocation.buses.last ?? busLeft) : busLeft
        return effectOutputSettings(effect: effect, busLeft: busLeft, busRight: busRight)
            + effectReturnSettings(effect: effect, allocation: allocation)
    }

    private static func effectOutputSettings(effect: Effect, busLeft: Int, busRight: Int) -> [WingSetting] {
        var settings: [WingSetting] = []
        if let output = effect.sendOutputs.first {
            settings.append(contentsOf: WingOutputSource(group: .bus, index: busLeft).settings(forOutput: output))
        }
        if effect.isStereo, effect.sendOutputs.count > 1 {
            settings.append(contentsOf: WingOutputSource(
                group: .bus,
                index: busRight
            ).settings(forOutput: effect.sendOutputs[1]))
        }
        return settings
    }

    private static func effectReturnSettings(effect: Effect, allocation: EffectRouting.Allocation) -> [WingSetting] {
        var settings: [WingSetting] = []
        if let channel = allocation.returnChannels.first, let input = effect.returnInputs.first {
            settings.append(contentsOf: WingSource(group: .local, index: input).settings(forChannel: channel))
        }
        if effect.isStereo, allocation.returnChannels.count > 1, effect.returnInputs.count > 1 {
            settings.append(contentsOf: WingSource(
                group: .local,
                index: effect.returnInputs[1]
            ).settings(forChannel: allocation.returnChannels[1]))
        }
        return settings
    }

    private static func spaceSettings(
        for allocations: [StudioEndpointAllocation],
        speakers: [Speaker]
    ) -> [WingSetting] {
        allocations
            .filter { $0.endpoint.destination == .space }
            .compactMap { allocation -> SpatialSource? in
                guard let placement = allocation.endpoint.placement else { return nil }
                return SpatialSource(
                    name: allocation.endpoint.name,
                    left: allocation.controlNode,
                    position: placement.position,
                    width: placement.width
                )
            }
            .flatMap { SpatialRouting.settings(for: $0, speakers: speakers) }
    }

    private static func send(kind: WingNodeKind, index: Int, toBus bus: Int) -> [WingSetting] {
        [
            WingSetting(address: WingAddress.sendOn(kind, index, toBus: bus), value: .int(1)),
            WingSetting(
                address: WingAddress.sendLevel(kind, index, toBus: bus),
                value: .float(EffectRouting.unitySendDecibels)
            )
        ]
    }

    private static func effectID(_ kind: StudioNodeKind) -> Effect.ID? {
        if case .effect(let id) = kind { return id }
        return nil
    }

    private static func uniqueSettings(_ settings: [WingSetting]) -> [WingSetting] {
        var latest: [String: WingSetting] = [:]
        for setting in settings {
            latest[setting.address] = setting
        }
        return settings.compactMap { setting in
            guard latest[setting.address] == setting else { return nil }
            latest[setting.address] = nil
            return setting
        }
    }

    private static func uniqueIssues(_ issues: [StudioCompileIssue]) -> [StudioCompileIssue] {
        var seen: Set<StudioCompileIssue.Kind> = []
        var result: [StudioCompileIssue] = []
        for issue in issues where !seen.contains(issue.kind) {
            seen.insert(issue.kind)
            result.append(issue)
        }
        return result
    }
}

private struct CompileContext {
    var graph: StudioGraph
    var effectByID: [Effect.ID: Effect]
    var assignmentByInstrument: [Equipment.ID: Equipment.ChannelAssignment]
    var effectAllocations: [Effect.ID: EffectRouting.Allocation]
    var endpointAllocationByNode: [StudioNode.ID: StudioEndpointAllocation]
    var appliableEdges: Set<StudioEdge.ID>

    init(
        graph: StudioGraph,
        effects: [Effect],
        assignments: [Equipment.ChannelAssignment],
        routingPlan: StudioRoutingPlan,
        resourcePlan: StudioResourcePlan
    ) {
        self.graph = graph
        effectByID = Dictionary(effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        assignmentByInstrument = Dictionary(
            assignments.map { ($0.equipment.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        effectAllocations = EffectRouting.allocations(for: effects)
        endpointAllocationByNode = Dictionary(
            resourcePlan.allocations.map { ($0.endpointNodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let allocatedEndpoints = Set(resourcePlan.allocations.map(\.endpoint.id))
        appliableEdges = Set(routingPlan.endpointPlans
            .filter { allocatedEndpoints.contains($0.endpoint.id) }
            .flatMap(\.edgeIDs))
    }

    func node(_ id: StudioNode.ID) -> StudioNode? {
        graph.node(id)
    }

    func isAppliable(_ edge: StudioEdge) -> Bool {
        appliableEdges.contains(edge.id)
    }

    func endpointBus(for nodeID: StudioNode.ID) -> Int? {
        endpointAllocationByNode[nodeID]?.controlNode.index
    }
}

private extension Equipment.ChannelAssignment {
    var channels: [Int] {
        [leftChannel, rightChannel].compactMap { $0 }
    }
}

private extension StudioCompileIssue {
    static func warning(_ kind: Kind, _ message: String) -> StudioCompileIssue {
        StudioCompileIssue(severity: .warning, kind: kind, message: message)
    }

    static func error(_ kind: Kind, _ message: String) -> StudioCompileIssue {
        StudioCompileIssue(severity: .error, kind: kind, message: message)
    }
}
