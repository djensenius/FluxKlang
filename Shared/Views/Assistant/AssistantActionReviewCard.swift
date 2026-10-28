import SwiftUI

/// The persisted card holds only display data. Only the planner's live review can open confirmation.
struct AssistantActionReviewCard: View {
    let reviewID: UUID
    let summary: String
    let planner: any AssistantActionPlanning
    @State private var displayedReview: AssistantActionReview?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("WING Action Review", systemImage: "checklist")
                .font(.headline)
            Text(summary)
            if let review = planner.pendingReview, review.id == reviewID {
                Button("Show Review") { displayedReview = review }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("assistant.action.showReview")
            } else if let result = planner.latestResult, result.reviewID == reviewID {
                AssistantActionResultView(result: result)
            } else {
                Text("""
                Inactive review. Restored or replaced cards cannot confirm changes. Send a new \
                request to review again.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant.action.inertCard")
            }
        }
        .padding()
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .sheet(item: $displayedReview) { review in
            AssistantActionReviewView(review: review, planner: planner)
        }
    }
}
