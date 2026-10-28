import SwiftUI

struct AssistantActionResultView: View {
    let result: AssistantActionResult
    var review: AssistantActionReview?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AssistantActionDisplay.resultTitle(result), systemImage: "checklist")
                .font(.headline)
                .accessibilityIdentifier("assistant.action.result")
            Text(result.message)
            Text(AssistantActionDisplay.localStatus(result.localStatus))
                .accessibilityIdentifier("assistant.action.localResult")
            ForEach(Array(result.members.enumerated()), id: \.offset) { _, member in
                VStack(alignment: .leading, spacing: 4) {
                    Text(memberTitle(member.node))
                        .font(.subheadline.weight(.semibold))
                    Text(AssistantActionDisplay.memberStatus(member.status))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("assistant.action.memberResult.\(member.node.id)")
            }
            Text("""
            Changes are not atomic. No automatic rollback or retry is performed. A sent but \
            unconfirmed change may have reached WING.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private func memberTitle(_ node: WingNodeRef) -> String {
        guard let target = review?.target,
              let index = target.members.firstIndex(where: { $0.identity.node == node }) else {
            return node.defaultLabel
        }
        let identity = target.members[index].identity
        let side = target.pairStripID == nil ? ""
            : AssistantActionDisplay.side(index: index, count: target.members.count)
        return "\(side)\(node.defaultLabel) · “\(identity.label)”"
    }
}
