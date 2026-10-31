//
//  GraphValidation.swift
//  FluxKlang
//
//  Structural validation of a neutral graph. Unlike `StudioRoutingPlanner`,
//  which reports issues and keeps going, a graph that fails here is rejected:
//  dangling references, incompatible ports and implicit feedback never load.
//

import Foundation

/// Why a graph is rejected.
enum GraphValidationError: Error, Hashable, Sendable {
    case bounds(ProjectGraphLimitError)
    case reviewRequired
    case invalidPosition(NodeID)
    case duplicateNode(NodeID)
    case duplicatePort(NodeID, PortID)
    case duplicateEdge(EdgeID)
    /// A second edge with the same `from` and `to` as an earlier one.
    case duplicateWire(EdgeID)
    case duplicateCapability(CapabilityID)
    case undefinedCapability(node: NodeID, CapabilityID)
    case unsupportedRequiredCapability(node: NodeID, CapabilityID)
    case conflictingCapabilityLevel(node: NodeID, CapabilityID)
    case nonRoutableNodeHasPorts(NodeID)
    /// The node's kind needs a reference it lacks (`role`, `asset` or `graph`).
    case missingReference(node: NodeID, field: String)
    /// An audio port without a confirmed 1...64 channel count, or a count on a
    /// non-audio port.
    case invalidChannelCount(NodeID, PortID)
    case missingNode(edge: EdgeID, NodeID)
    case missingPort(edge: EdgeID, PortAddress)
    case wrongDirection(edge: EdgeID)
    case signalMismatch(edge: EdgeID, from: PortSignal, to: PortSignal)
    case channelMismatch(edge: EdgeID, from: Int, to: Int)
    case invalidConversion(edge: EdgeID)
    case invalidFeedback(edge: EdgeID)
    /// Nodes on (or between) cycles that no explicit feedback edge breaks.
    case cycleWithoutFeedback([NodeID])
    /// Strict validation only: unmodelled members at a JSON-like path.
    case unknownFields(path: String)
}

extension GraphPort {
    static let channelRange = 1...64

    var hasValidChannels: Bool {
        guard signal == .audio else { return channels == nil }
        return channels.map(Self.channelRange.contains) ?? false
    }
}

extension GraphDocument {
    /// Every reason this graph is rejected, in document order; empty when valid.
    /// `strict` also rejects unknown members, so drift is caught.
    func validationErrors(strict: Bool = false) -> [GraphValidationError] {
        do { try checkCollectionBounds() } catch { return [.bounds(error)] }
        var errors = nodeErrors()
        if requiresReview { errors.insert(.reviewRequired, at: 0) }
        var linked: [(NodeID, NodeID)] = []
        var wires: Set<[String]> = []
        var edgeIDs: Set<EdgeID> = []
        for edge in edges {
            if !edgeIDs.insert(edge.id).inserted { errors.append(.duplicateEdge(edge.id)) }
            let wire = [edge.from.node, edge.to.node].map(\.rawValue) + [edge.from.port, edge.to.port].map(\.rawValue)
            if !wires.insert(wire).inserted { errors.append(.duplicateWire(edge.id)) }
            let edgeErrors = errorsForEdge(edge)
            errors += edgeErrors
            if edgeErrors.isEmpty, edge.feedback == nil { linked.append((edge.from.node, edge.to.node)) }
        }
        let looping = Self.nodesOnCycles(linked)
        if !looping.isEmpty { errors.append(.cycleWithoutFeedback(looping)) }
        if strict { errors += unknownFieldErrors() }
        return errors
    }

    /// Throws the first validation error.
    func validate(strict: Bool = false) throws(GraphValidationError) {
        if let first = validationErrors(strict: strict).first { throw first }
    }

    /// A pure prerequisite check against this host's explicitly supplied capability IDs.
    /// Passing is not preparation, a live capability observation, or activation authority.
    func validateForPreparation(supportedCapabilities: Set<CapabilityID>) throws(GraphValidationError) {
        try validate()
        for node in nodes {
            for capability in node.requiredCapabilities where !supportedCapabilities.contains(capability) {
                throw .unsupportedRequiredCapability(node: node.id, capability)
            }
        }
    }

    private func nodeErrors() -> [GraphValidationError] {
        var errors: [GraphValidationError] = []
        var defined: Set<CapabilityID> = []
        for capability in capabilities where !defined.insert(capability.id).inserted {
            errors.append(.duplicateCapability(capability.id))
        }
        var nodeIDs: Set<NodeID> = []
        for node in nodes {
            if !nodeIDs.insert(node.id).inserted { errors.append(.duplicateNode(node.id)) }
            if let position = node.position, !position.x.isFinite || !position.y.isFinite {
                errors.append(.invalidPosition(node.id))
            }
            if !node.kind.isRoutable, !node.ports.isEmpty { errors.append(.nonRoutableNodeHasPorts(node.id)) }
            if let field = node.missingReferenceField { errors.append(.missingReference(node: node.id, field: field)) }
            errors += portErrors(node)
            for capability in node.requiredCapabilities + node.advisoryCapabilities
            where !defined.contains(capability) {
                errors.append(.undefinedCapability(node: node.id, capability))
            }
            for capability in Set(node.requiredCapabilities).intersection(node.advisoryCapabilities)
                .sorted() {
                errors.append(.conflictingCapabilityLevel(node: node.id, capability))
            }
        }
        return errors
    }

    private func portErrors(_ node: GraphNode) -> [GraphValidationError] {
        var errors: [GraphValidationError] = []
        var ids: Set<PortID> = []
        for port in node.ports {
            if !ids.insert(port.id).inserted { errors.append(.duplicatePort(node.id, port.id)) }
            if !port.hasValidChannels { errors.append(.invalidChannelCount(node.id, port.id)) }
        }
        return errors
    }

    private func errorsForEdge(_ edge: GraphEdge) -> [GraphValidationError] {
        var errors: [GraphValidationError] = []
        var ports: [GraphPort] = []
        for address in [edge.from, edge.to] {
            if node(address.node) == nil {
                errors.append(.missingNode(edge: edge.id, address.node))
            } else if let port = port(at: address), node(address.node)?.kind.isRoutable == true {
                ports.append(port)
            } else {
                errors.append(.missingPort(edge: edge.id, address))
            }
        }
        if let feedback = edge.feedback, !feedback.isValid { errors.append(.invalidFeedback(edge: edge.id)) }
        guard errors.isEmpty, let source = ports.first, let destination = ports.last else { return errors }
        guard source.direction == .output, destination.direction == .input else {
            return [.wrongDirection(edge: edge.id)]
        }
        guard source.signal == destination.signal else {
            return [.signalMismatch(edge: edge.id, from: source.signal, to: destination.signal)]
        }
        // Unconfirmed or invalid channel counts are reported on the port itself.
        guard source.signal == .audio, source.hasValidChannels, destination.hasValidChannels,
              let width = source.channels, let rows = destination.channels else {
            return edge.conversion == nil ? [] : [.invalidConversion(edge: edge.id)]
        }
        if let conversion = edge.conversion {
            let valid = conversion.map.count == rows && conversion.map.contains { !$0.isEmpty }
                && conversion.map.allSatisfy { $0.allSatisfy { (0..<width).contains($0) } }
            return valid ? [] : [.invalidConversion(edge: edge.id)]
        }
        return width == rows ? [] : [.channelMismatch(edge: edge.id, from: width, to: rows)]
    }

    /// Peels nodes with no incoming or no outgoing links until none remain; any
    /// survivors lie on, or between, cycles.
    static func nodesOnCycles<ID: Hashable & Comparable>(_ links: [(ID, ID)]) -> [ID] {
        var outgoing: [ID: [ID]] = [:], incoming: [ID: [ID]] = [:]
        var inCount: [ID: Int] = [:], outCount: [ID: Int] = [:]
        let nodes = Set(links.flatMap { [$0.0, $0.1] })
        for (source, destination) in links {
            outgoing[source, default: []].append(destination)
            incoming[destination, default: []].append(source)
            inCount[destination, default: 0] += 1
            outCount[source, default: 0] += 1
        }
        var queue = nodes.filter { inCount[$0, default: 0] == 0 || outCount[$0, default: 0] == 0 }.sorted()
        var removed: Set<ID> = []
        var index = 0
        while index < queue.count {
            let node = queue[index]
            index += 1
            guard removed.insert(node).inserted else { continue }
            for destination in outgoing[node] ?? [] {
                inCount[destination, default: 0] -= 1
                if inCount[destination] == 0 { queue.append(destination) }
            }
            for source in incoming[node] ?? [] {
                outCount[source, default: 0] -= 1
                if outCount[source] == 0 { queue.append(source) }
            }
        }
        return nodes.subtracting(removed).sorted()
    }

    private func unknownFieldErrors() -> [GraphValidationError] {
        var found: [(String, [String: JSONValue])] = [("$", unknownFields)]
        found += capabilities.map { ("$.capabilities[\($0.id)]", $0.unknownFields) }
        for node in nodes {
            let path = "$.nodes[\(node.id)]"
            found += [(path, node.unknownFields), (path + ".position", node.position?.unknownFields ?? [:])]
            found += node.ports.map { ("\(path).ports[\($0.id)]", $0.unknownFields) }
        }
        for edge in edges {
            let path = "$.edges[\(edge.id)]"
            found += [
                (path, edge.unknownFields), (path + ".from", edge.from.unknownFields),
                (path + ".to", edge.to.unknownFields),
                (path + ".conversion", edge.conversion?.unknownFields ?? [:]),
                (path + ".feedback", edge.feedback?.unknownFields ?? [:])
            ]
        }
        return found.filter { !$0.1.isEmpty }.map { .unknownFields(path: $0.0) }
    }
}

extension GraphNode {
    /// The reference this node's kind requires but lacks, if any.
    var missingReferenceField: String? {
        if kind.requiresRole, role == nil { return "role" }
        if kind == .mediaPlayer, asset == nil { return "asset" }
        if kind == .sharedGraph, graph == nil { return "graph" }
        return nil
    }
}
