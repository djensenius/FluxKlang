//
//  StudioResourceAllocator.swift
//  FluxKlang
//
//  Lowers semantic endpoint/stem plans into WING resources without exposing those
//  resources in the primary workflow. This is deliberately separate from
//  `EffectRouting`: the semantic compiler can reserve effect buses, speaker buses
//  and endpoint buses together before emitting concrete OSC settings.
//

import Foundation

struct StudioEndpointAllocation: Identifiable, Hashable, Sendable {
    var endpoint: StudioEndpoint
    var endpointNodeID: StudioNode.ID
    /// The WING strip used as this endpoint's generated controllable stem.
    var controlNode: WingNodeRef

    var id: StudioEndpoint.ID { endpoint.id }
}

struct StudioResourceIssue: Identifiable, Hashable, Sendable {
    enum Severity: String, Hashable, Sendable {
        case warning
        case error
    }

    enum Kind: Hashable, Sendable {
        case emptyEndpoint(endpointID: StudioEndpoint.ID)
        case noAvailableBus(endpointID: StudioEndpoint.ID)
    }

    var severity: Severity
    var kind: Kind
    var message: String

    var id: String { "\(severity.rawValue)-\(message)-\(kind)" }
}

struct StudioResourcePlan: Hashable, Sendable {
    var allocations: [StudioEndpointAllocation]
    var issues: [StudioResourceIssue]

    var hasErrors: Bool { issues.contains { $0.severity == .error } }
}

enum StudioResourceAllocator {
    private static let maxNameLength = 12

    /// Allocates one bus-master stem per non-empty endpoint, excluding speaker
    /// buses and buses already reserved for outboard effects.
    static func allocateEndpoints(
        for routingPlan: StudioRoutingPlan,
        effects: [Effect],
        speakers: [Speaker]
    ) -> StudioResourcePlan {
        var availableBuses = availableEndpointBuses(effects: effects, speakers: speakers)
        var allocations: [StudioEndpointAllocation] = []
        var issues: [StudioResourceIssue] = []

        for endpointPlan in routingPlan.endpointPlans {
            guard !endpointPlan.sourceNodeIDs.isEmpty else {
                issues.append(.warning(
                    .emptyEndpoint(endpointID: endpointPlan.endpoint.id),
                    "\(endpointPlan.endpoint.name) has nothing feeding it yet."
                ))
                continue
            }
            guard !availableBuses.isEmpty else {
                issues.append(.error(
                    .noAvailableBus(endpointID: endpointPlan.endpoint.id),
                    "No free WING bus is available for \(endpointPlan.endpoint.name)."
                ))
                continue
            }
            let bus = availableBuses.removeFirst()
            allocations.append(StudioEndpointAllocation(
                endpoint: endpointPlan.endpoint,
                endpointNodeID: endpointPlan.nodeID,
                controlNode: .bus(bus)
            ))
        }

        return StudioResourcePlan(allocations: allocations, issues: issues)
    }

    /// Initial WING settings for generated endpoint stems. The fader/mute/meter
    /// controls use the allocated bus strip directly; these settings only name the
    /// strip and route Final Mix endpoints to Main 1.
    static func settings(for allocation: StudioEndpointAllocation) -> [WingSetting] {
        var settings = [
            WingSetting(
                address: WingAddress.name(allocation.controlNode.kind, allocation.controlNode.index),
                value: .string(sanitizeName(allocation.endpoint.name))
            )
        ]
        if allocation.endpoint.destination == .finalMix {
            settings.append(WingSetting(
                address: WingAddress.mainOn(.bus, allocation.controlNode.index, toMain: EffectRouting.returnMain),
                value: .int(1)
            ))
        }
        return settings
    }

    static func settings(for plan: StudioResourcePlan) -> [WingSetting] {
        plan.allocations.flatMap(settings)
    }

    private static func availableEndpointBuses(effects: [Effect], speakers: [Speaker]) -> [Int] {
        let speakerBuses = speakers.compactMap { speaker -> Int? in
            speaker.node.kind == .bus ? speaker.node.index : nil
        }
        let effectBuses = EffectRouting.allocations(for: effects).values.flatMap(\.buses)
        let reserved = Set(speakerBuses + effectBuses)
        return (1...WingNodeKind.bus.count).filter { !reserved.contains($0) }
    }

    private static func sanitizeName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }
}

private extension StudioResourceIssue {
    static func warning(_ kind: Kind, _ message: String) -> StudioResourceIssue {
        StudioResourceIssue(severity: .warning, kind: kind, message: message)
    }

    static func error(_ kind: Kind, _ message: String) -> StudioResourceIssue {
        StudioResourceIssue(severity: .error, kind: kind, message: message)
    }
}
