import SwiftUI

/// Keeps the advisor's named paths authoritative; policy labels describe the
/// corresponding request without rebuilding or guessing a routing topology.
struct PendingStudioRoutingSummaryView: View {
    let draft: StudioPatchDraft

    private var routes: [StudioWiringRoute] {
        [StudioWiringRoute(
            sourceInstrumentIDs: draft.request.sourceInstrumentIDs,
            effectChainIDs: draft.request.effectChainIDs,
            destination: draft.request.destination,
            includesDrySignal: draft.request.includesDrySignal,
            outputConnectors: draft.request.outputConnectors
        )] + draft.request.additionalRoutes
    }

    private struct PathPolicy {
        var branch: Int
        var path: Int
        var text: String
    }

    private var pathPolicies: [PathPolicy] {
        routes.enumerated().flatMap { index, route in
            if route.effectChainIDs.isEmpty {
                return [PathPolicy(branch: index + 1, path: 1, text: "Direct path · no effects")]
            }
            if route.includesDrySignal {
                return [
                    PathPolicy(branch: index + 1, path: 1, text: "Dry path · parallel with the processed (wet) path"),
                    PathPolicy(branch: index + 1, path: 2, text: "Processed (wet) path · parallel with the dry path")
                ]
            }
            return [PathPolicy(branch: index + 1, path: 1, text: "Processed-only (wet) · no parallel dry path")]
        }
    }

    private func pathIdentifier(at index: Int) -> String {
        guard pathPolicies.count == draft.logicalRoutingSummary.count else {
            return "assistant.pendingDraft.unmatchedPath.\(index + 1)"
        }
        let policy = pathPolicies[index]
        return "assistant.pendingDraft.branch.\(policy.branch).path.\(policy.path)"
    }

    var body: some View {
        Text("\(routes.count) branches · \(draft.logicalRoutingSummary.count) logical paths")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("assistant.pendingDraft.routingCount")
        ForEach(Array(draft.logicalRoutingSummary.enumerated()), id: \.offset) { index, summary in
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.value)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(pathIdentifier(at: index)).source-to-destination")
                if pathPolicies.count == draft.logicalRoutingSummary.count,
                   pathPolicies.indices.contains(index) {
                    let policy = pathPolicies[index]
                    Text("Branch \(policy.branch) · \(policy.text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(pathIdentifier(at: index)).signalPolicy")
                }
            }
        }
    }
}
