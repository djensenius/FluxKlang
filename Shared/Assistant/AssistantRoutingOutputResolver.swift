import Foundation

/// Saved configuration evidence, rechecked at review/acceptance rather than retaining stale alias coordinates.
struct AssistantRoutingOutputReference: Codable, Hashable, Sendable {
    var mention: String
    var groupName: String
    var connectors: [WingOutputConnector]

    func isValid(in connections: StudioHomeConnections) -> Bool {
        guard let resolved = AssistantRoutingOutputResolver.resolve(mention, in: connections) else { return false }
        return resolved.reference.groupName == groupName && resolved.reference.connectors == connectors
    }
}

enum AssistantRoutingOutputResolver {
    struct Group {
        var name: String
        var outputs: [StudioOutputConnection]
        var connectors: [WingOutputConnector] { outputs.map(\.outputConnector) }
        var isComplete: Bool {
            let sides = outputs.compactMap { side($0.destinationName ?? "") }
            return outputs.count == 2 && Set(sides) == Set(["l", "r"])
                && Set(connectors).count == 2
                && outputs.allSatisfy { $0.bank.connectorRange.contains($0.connector) }
        }
    }

    struct Resolution {
        var destination: StudioEndpointDestination
        var reference: AssistantRoutingOutputReference
    }

    static func resolve(_ mention: String, in connections: StudioHomeConnections) -> Resolution? {
        let key = alias(mention)
        let allGroups = groups(in: connections)
        let matches: [Group]
        let destination: StudioEndpointDestination
        if ["main", "mains", "main speakers", "speakers", "final mix", "mix"].contains(key) {
            matches = allGroups.filter { alias($0.name) == "main speakers" }
            destination = .finalMix
        } else {
            matches = allGroups.filter { alias($0.name) == key }
            destination = .custom
        }
        guard matches.count == 1, let group = matches.first, group.isComplete,
              group.connectors.allSatisfy({ connector in
                  connections.outputs.filter { $0.outputConnector == connector }.count == 1
              }) else { return nil }
        return Resolution(destination: destination,
            reference: .init(mention: mention, groupName: group.name, connectors: group.connectors))
    }

    static func groups(in connections: StudioHomeConnections) -> [Group] {
        let outputs = connections.outputs.filter { $0.equipmentID == nil && $0.destinationName != nil }
        let grouped = Dictionary(grouping: outputs) { baseName($0.destinationName ?? "") }
        return grouped.map { name, outputs in
            Group(name: name, outputs: outputs.sorted {
                (side($0.destinationName ?? "") ?? "", $0.bank.rawValue, $0.connector)
                    < (side($1.destinationName ?? "") ?? "", $1.bank.rawValue, $1.connector)
            })
        }.sorted { $0.name < $1.name }
    }

    static func baseName(_ name: String) -> String {
        let normalized = AssistantRoutingInterpretationAdapter.normalize(name)
        for suffix in [" left", " right", " l", " r"] where normalized.hasSuffix(suffix) {
            return String(normalized.dropLast(suffix.count))
        }
        return normalized
    }

    private static func alias(_ name: String) -> String {
        let normalized = baseName(name)
        return normalized == "desktop speakers" ? "desk speakers" : normalized
    }

    private static func side(_ name: String) -> String? {
        let normalized = AssistantRoutingInterpretationAdapter.normalize(name)
        if normalized.hasSuffix(" l") || normalized.hasSuffix(" left") { return "l" }
        if normalized.hasSuffix(" r") || normalized.hasSuffix(" right") { return "r" }
        return nil
    }
}
