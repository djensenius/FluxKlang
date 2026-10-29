import SwiftUI

/// The snapshot keeps the sheet stable after one-shot consumption. It is never authorization.
struct AssistantActionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let planner: any AssistantActionPlanning
    @State private var snapshot: AssistantActionReview
    @State private var result: AssistantActionResult?
    @State private var isSelecting = false
    @State private var isConfirming = false
    @State private var cancellationRequested = false
    @State private var notice: String?

    init(review: AssistantActionReview, planner: any AssistantActionPlanning) {
        self.planner = planner
        _snapshot = State(initialValue: review)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                reviewContent(now: context.date)
                    .safeAreaInset(edge: .bottom) { confirmationFooter(now: context.date) }
            }
            .navigationTitle("Review WING Action")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isConfirming ? "Stop Remaining Changes" : outcome == nil ? "Cancel" : "Done") {
                        if isConfirming {
                            cancel()
                        } else {
                            if outcome == nil { cancel() }
                            dismiss()
                        }
                    }
                    .disabled(isConfirming && cancellationRequested)
                    .accessibilityIdentifier("assistant.action.cancel")
                }
            }
            .onDisappear {
                // Swiping away a consumed review must still revoke any queued member writes.
                if isConfirming || isSelecting || planner.pendingReview?.id == snapshot.id { cancel() }
            }
        }
        .accessibilityIdentifier("assistant.action.review")
    }

    private var outcome: AssistantActionResult? {
        if let result { return result }
        guard planner.latestResult?.reviewID == snapshot.id else { return nil }
        return planner.latestResult
    }

    private var activeReview: AssistantActionReview? {
        // If a service replaces evidence under the same ID, the old displayed meaning is inert too.
        guard let review = planner.pendingReview, review == snapshot else { return nil }
        return review
    }

    private func reviewContent(now: Date) -> some View {
        Form {
            if let outcome {
                Section { AssistantActionResultView(result: outcome, review: snapshot) }
            } else {
                Section("Proposed action") {
                    Text(snapshot.summary)
                    if let suggestion = AssistantActionDisplay.suggestedChange(snapshot) {
                        Text(suggestion)
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("assistant.action.suggestedAmount")
                    }
                    if snapshot.addsLiveShortcut {
                        Text("""
                        Add a shortcut to the existing live channel, not new Equipment. No cables, \
                        routing, buses or input assignments are created.
                        """)
                    }
                    Text("""
                    Percent means fader travel, not loudness or amplitude: 50% travel = −10 dB. 0% \
                    is Off (−∞ dB); mute is separate.
                    """)
                        .font(.caption)
                        .accessibilityIdentifier("assistant.action.percentSemantics")
                }
                if snapshot.stage == .chooseCandidate {
                    candidateSection(now: now)
                } else {
                    AssistantActionChangesView(review: snapshot)
                }
                Section("Safety and validity") {
                    ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                    }
                    Text("""
                    Expires \(snapshot.expiresAt.formatted(date: .omitted, time: .standard)). \
                    Fresh identity and values are checked again on confirmation.
                    """)
                        .font(.caption)
                    if isConfirming {
                        ProgressView("Checking / sending reviewed changes…")
                            .accessibilityIdentifier("assistant.action.confirming")
                        Text("The review has been consumed. Do not retry while the result is pending.")
                    } else if now >= snapshot.expiresAt {
                        Text("Review expired. Send a new request; no confirmation is available.")
                            .accessibilityIdentifier("assistant.action.expired")
                    } else if activeReview == nil {
                        Text("This review is inactive or replaced. Send a new request to review again.")
                            .accessibilityIdentifier("assistant.action.inactive")
                    }
                    if cancellationRequested {
                        Text("""
                        Cancellation requested. Remaining queued changes are revoked; changes \
                        already sent cannot be undone.
                        """)
                    }
                    if let notice { Text(notice) }
                    Text("""
                    Changes are not atomic. A shortcut may be added before hardware changes. Stereo \
                    members are sent separately; cancellation or failure may leave a partial result. \
                    There is no automatic rollback or retry.
                    """)
                        .font(.caption)
                }
            }
        }
    }

    private func candidateSection(now: Date) -> some View {
        Section("Choose the exact live channel or saved pair") {
            Text("Similarly named labels are suggestions, not proof of attached instruments.")
                .font(.caption)
            ForEach(snapshot.candidates) { candidate in
                Button {
                    select(candidate)
                } label: {
                    AssistantActionCandidateView(candidate: candidate)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(activeReview == nil || now >= snapshot.expiresAt || isSelecting || cancellationRequested)
                .accessibilityIdentifier("assistant.action.candidate.\(candidate.id)")
            }
            if isSelecting { ProgressView("Refreshing selected channel…") }
        }
    }

    @ViewBuilder
    private func confirmationFooter(now: Date) -> some View {
        if outcome == nil && snapshot.stage == .ready {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.faderChanges.isEmpty
                    ? "Confirm adds only the local shortcut. No hardware writes."
                    : "Confirm writes the reviewed existing WING fader / mute values to hardware.")
                    .font(.caption)
                Button {
                    confirm()
                } label: {
                    Text(snapshot.faderChanges.isEmpty
                        ? "Confirm — Add Local Shortcut" : "Confirm — Write to WING Hardware")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(activeReview?.stage != .ready || now >= snapshot.expiresAt
                    || isConfirming || isSelecting || cancellationRequested)
                .accessibilityIdentifier("assistant.action.confirm")
            }
            .padding()
            .background(.bar)
        }
    }

    private func select(_ candidate: AssistantActionCandidate) {
        guard let review = activeReview, !isSelecting, !cancellationRequested,
              Date() < review.expiresAt else { return }
        isSelecting = true
        Task { @MainActor in
            let preparation = await planner.selectCandidate(reviewID: review.id, candidateID: candidate.id)
            isSelecting = false
            guard !cancellationRequested else { return }
            switch preparation {
            case .review(let refreshed):
                // Render fresh service evidence, never turn the old display snapshot into a plan.
                if let pending = planner.pendingReview, pending.id == refreshed.id { snapshot = pending }
            case .clarification(let message): notice = message
            case .answer: notice = "No actionable review remains. Send a new request."
            }
        }
    }

    private func confirm() {
        guard let review = activeReview, review.stage == .ready, outcome == nil,
              !isConfirming, !isSelecting, !cancellationRequested, Date() < review.expiresAt else { return }
        isConfirming = true
        Task { @MainActor in
            result = await planner.confirm(reviewID: review.id)
            isConfirming = false
        }
    }

    private func cancel() {
        cancellationRequested = true
        planner.cancel()
    }
}
