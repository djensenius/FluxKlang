import SwiftUI

/// Inspects every change against the document base, not an active engine graph.
/// No ReviewSheetInput/activation phase is needed to render a WiringReviewDiff.
struct PerformanceDraftReviewView: View {
    let diff: WiringReviewDiff
    let baseRevision: ContractRevision

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draft changes").font(.title2)
            Text("Document base revision \(baseRevision.description) — unchanged")
                .font(.caption)
            Text("Not active. Native activation unavailable.")
                .foregroundStyle(.secondary)
            if diff.isEmpty {
                Text("No changes from the empty document base.")
            }
            ForEach(diff.groups, id: \.kind) { group in
                Text(heading(group.kind)).font(.headline)
                ForEach(group.changes, id: \.sortID) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        changeDetails(change)
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ kind: WiringReviewChangeKind) -> String {
        switch kind {
        case .addedNode: "Added nodes"
        case .movedNode: "Moved nodes"
        case .removedNode: "Removed nodes"
        case .addedEdge: "Added connections"
        case .removedEdge: "Removed connections"
        }
    }

    @ViewBuilder
    private func changeDetails(_ change: WiringReviewChange) -> some View {
        switch change {
        case .addedNode(let node), .removedNode(let node):
            Text("\(node.label) (\(node.id.rawValue))")
            Text(node.kind.rawValue).font(.caption)
            if let role = node.role { Text("Role: \(role.rawValue)") }
            if let asset = node.asset { Text("Asset: \(asset.rawValue)") }
            if let graph = node.graph { Text("Graph: \(graph.rawValue)") }
            ForEach(node.ports) { port in
                Text("\(port.id.rawValue): \(port.direction.rawValue) \(port.signal.rawValue)"
                     + (port.channels.map { " • \($0) channels" } ?? ""))
            }
            Text("Position: \(position(node.position))")
            completeRecord(node)
        case .movedNode(let node, let from, let destination):
            Text(node.rawValue)
            Text("\(position(from)) → \(position(destination))")
            completeRecord([from, destination])
        case .addedEdge(let edge), .removedEdge(let edge):
            Text(edge.id.rawValue)
            Text("\(edge.from.node.rawValue).\(edge.from.port.rawValue)"
                 + " → \(edge.to.node.rawValue).\(edge.to.port.rawValue)")
            if let conversion = edge.conversion {
                Text("Explicit channel map: \(String(describing: conversion.map))")
            } else {
                Text("Direct connection — no channel conversion")
            }
            if let feedback = edge.feedback {
                Text("Feedback: \(feedback.delayBlocks) blocks, ceiling \(feedback.gainCeilingDb) dB")
            }
            completeRecord(edge)
        }
    }

    private func position(_ point: GraphPoint?) -> String {
        guard let point else { return "Unplaced" }
        return "(\(point.x), \(point.y))"
    }

    /// Keep optional/extension fields inspectable too; no record is summarized away.
    private func completeRecord(_ value: some Encodable) -> some View {
        DisclosureGroup("Complete record") {
            Text(encodedRecord(value)).font(.caption.monospaced())
        }
    }

    private func encodedRecord(_ value: some Encodable) -> String {
        do {
            let data = try ContractCoding.makeEncoder().encode(value)
            guard let record = String(bytes: data, encoding: .utf8) else {
                return "Record could not be displayed: encoded data is not valid UTF-8."
            }
            return record
        } catch {
            return "Record could not be displayed: \(error)"
        }
    }
}
