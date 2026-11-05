/// Derives the project roles an adapted legacy graph references, only from what the graph says.
/// Channel counts are carried exactly as the ports state them: the adapter marks imported audio ports
/// unconfirmed (`nil`), so their roles stay unconfirmed. Nothing is invented, widened or confirmed.
enum LegacyAdoptionRoles {
    /// The role direction a node kind implies, matching `ProjectDocument`'s reference check.
    static func direction(of kind: NodeKind) -> PortDirection? {
        switch kind {
        case .roleInput: .input
        case .roleOutput, .spatialBus: .output
        default: nil
        }
    }

    /// One role per distinct `RoleID`, sorted by `RoleID`. The label is the first referencing node's
    /// label in document order. Disagreement among a role's nodes refuses; nothing is merged.
    ///
    /// Refusals are deterministic: nodes are checked in document order, and the first node that makes
    /// its role wrongly wired or inconsistent (direction, signal or channel count) names the refused role.
    ///
    /// An unwired role node (no ports) is `.audio` with no channel count: `ProjectRole.signal` cannot be
    /// empty, and the adapter marks every legacy port audio. Its count stays unconfirmed, so the role is
    /// listed in `LegacyAdoptionResult.unconfirmedChannelRoles` and the graph still requires review.
    static func derive(from graph: GraphDocument) throws(LegacyAdoptionRefusal) -> [ProjectRole] {
        var found: [RoleID: Accumulator] = [:]
        for node in graph.nodes {
            guard let direction = direction(of: node.kind), let id = node.role else { continue }
            // A role input feeds the graph through output ports, and vice versa.
            guard node.ports.allSatisfy({ $0.direction != direction }) else { throw .roleShapeMismatch(id) }
            var entry = found[id] ?? Accumulator(label: node.label, direction: direction)
            guard entry.direction == direction else { throw .conflictingRole(id) }
            for port in node.ports {
                entry.signals.insert(port.signal)
                entry.channels.insert(port.channels)
            }
            guard entry.signals.count <= 1, entry.channels.count <= 1 else { throw .conflictingRole(id) }
            found[id] = entry
        }
        return found.map { id, entry in
            ProjectRole(
                id: id, label: entry.label, direction: entry.direction,
                signal: entry.signals.first ?? .audio, channels: entry.channels.first ?? nil
            )
        }.sorted { $0.id < $1.id }
    }

    private struct Accumulator {
        let label: String
        let direction: PortDirection
        var signals: Set<PortSignal> = []
        var channels: Set<Int?> = []
    }
}
