import SwiftUI

struct AssistantActionCandidateView: View {
    let candidate: AssistantActionCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.title)
                .font(.headline)
            if candidate.pairStripID != nil {
                Label("Explicit saved stereo pair · left / right", systemImage: "rectangle.split.2x1")
                    .font(.caption)
            }
            ForEach(Array(candidate.members.enumerated()), id: \.offset) { index, member in
                AssistantActionIdentityView(
                    identity: member,
                    side: AssistantActionDisplay.side(index: index, count: candidate.members.count)
                )
            }
            Text("Match: \(candidate.match.rawValue). Selection refreshes evidence; it does not write to WING.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("Select & Refresh Review", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AssistantActionIdentityView: View {
    let identity: AssistantActionChannelIdentity
    var side = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(side)\(identity.node.defaultLabel) · “\(identity.label)”")
                .font(.subheadline.weight(.semibold))
            Text(AssistantActionDisplay.source(group: identity.sourceGroup, index: identity.sourceIndex))
            Text(AssistantActionDisplay.linkage(identity.equipmentID))
        }
        .font(.caption)
    }
}

struct AssistantActionChangesView: View {
    let review: AssistantActionReview

    var body: some View {
        if let target = review.target {
            Section(target.pairStripID == nil ? "Reviewed channel" : "Explicit stereo pair · left / right") {
                ForEach(Array(target.members.enumerated()), id: \.offset) { index, member in
                    VStack(alignment: .leading, spacing: 8) {
                        AssistantActionIdentityView(
                            identity: member.identity,
                            side: AssistantActionDisplay.side(index: index, count: target.members.count)
                        )
                        if let change = review.faderChanges.first(where: { $0.node == member.identity.node }) {
                            let before = AssistantActionDisplay.level(
                                position: change.beforePosition, muted: change.beforeMuted
                            )
                            let after = AssistantActionDisplay.level(
                                position: change.afterPosition, muted: change.afterMuted
                            )
                            Text("Before: \(before)")
                            Text("After: \(after)")
                                .fontWeight(.semibold)
                        } else {
                            let observed = AssistantActionDisplay.level(position: member.position, muted: member.muted)
                            Text("Observed: \(observed)")
                            Text("No fader or mute change requested.")
                        }
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("assistant.action.change.\(member.identity.node.id)")
                }
            }
        }
    }
}
