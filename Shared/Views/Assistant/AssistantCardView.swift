import SwiftUI

struct AssistantCardView: View {
    @Environment(AppModel.self) private var appModel
    let card: AssistantCard

    var body: some View {
        Group {
            switch card {
            case .help(let topic, let title, let overview):
                AssistantInlineCard(title: title, systemImage: "book") {
                    Text(overview)
                    Button("Open Help") {
                        appModel.assistant.navigationTarget = .help(topic)
                    }
                }
            case .wiring(let summary, let cables):
                AssistantInlineCard(title: "Wiring", systemImage: "cable.connector") {
                    ForEach(Array(summary.enumerated()), id: \.offset) {
                        Text($0.element)
                    }
                    ForEach(Array(cables.enumerated()), id: \.offset) {
                        Label($0.element, systemImage: "arrow.right")
                    }
                }
            case .conflicts(let issues):
                AssistantInlineCard(title: "Conflicts", systemImage: "exclamationmark.triangle") {
                    if issues.isEmpty {
                        Text("No current conflicts.")
                    } else {
                        ForEach(Array(issues.enumerated()), id: \.offset) {
                            Label($0.element, systemImage: "exclamationmark.circle")
                        }
                    }
                }
            case .moves(let moves):
                AssistantInlineCard(title: "Temporary Moves", systemImage: "arrow.triangle.swap") {
                    ForEach(Array(moves.enumerated()), id: \.offset) {
                        Text($0.element)
                    }
                }
            case .actionReview(let id, let summary):
                AssistantActionReviewCard(submissionID: id, summary: summary, planner: appModel.assistantActions)
            case .pendingDraft(let id, let summary, let hasErrors):
                AssistantInlineCard(title: "Pending Draft", systemImage: "doc.badge.clock") {
                    Text(summary)
                    if appModel.assistant.isPendingDraft(id) {
                        if hasErrors {
                            Label("Resolve validation errors before accepting.", systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                        Button("Review Draft") {
                            appModel.assistant.openReview(ofDraft: id)
                        }
                        .accessibilityIdentifier("assistant.draftReviewCard")
                    } else {
                        Text("This draft is no longer pending.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("assistant.draftReviewCard.inactive")
                    }
                }
            }
        }
    }
}

private struct AssistantInlineCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
