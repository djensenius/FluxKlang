#if DEBUG
import Observation
import SwiftUI

/// UI-only value fixtures. Both launch flags are required; this planner has no AppModel or WING access.
struct AssistantActionUITestFixtureModifier: ViewModifier {
    @State private var showsFixture = false
    @State private var didPresent = false

    private var mode: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              let index = arguments.firstIndex(of: "-ui-test-action-review"),
              arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return ["candidate", "ready", "expired", "restored", "partial", "confirming"].contains(value) ? value : nil
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if mode != nil && !didPresent {
                    didPresent = true
                    showsFixture = true
                }
            }
            .sheet(isPresented: $showsFixture) {
                if let mode { AssistantActionUITestFixtureHost(mode: mode) }
            }
    }
}

private struct AssistantActionUITestFixtureHost: View {
    @State private var planner: AssistantActionUITestPlanner
    private let mode: String

    init(mode: String) {
        self.mode = mode
        _planner = State(initialValue: AssistantActionUITestPlanner(mode: mode))
    }

    var body: some View {
        Group {
            if mode == "restored" || mode == "confirming" {
                NavigationStack {
                    ScrollView {
                        AssistantActionReviewCard(
                            submissionID: planner.fixtureReview.submissionID,
                            summary: planner.fixtureReview.summary,
                            planner: planner
                        )
                        .padding()
                    }
                    .navigationTitle(mode == "restored" ? "Restored Action Card" : "WING Action Card")
                }
            } else {
                AssistantActionReviewView(review: planner.fixtureReview, planner: planner)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("Fixture confirm calls: \(planner.confirmCalls)")
                .font(.caption2)
                .padding(4)
                .background(.background)
                .allowsHitTesting(false)
                .accessibilityIdentifier("assistant.action.fixtureConfirmCalls")
        }
    }
}

@MainActor @Observable
private final class AssistantActionUITestPlanner: AssistantActionPlanning {
    let fixtureReview: AssistantActionReview
    var pendingReview: AssistantActionReview?
    var latestResult: AssistantActionResult?
    var confirmCalls = 0
    private let waitsForCancellation: Bool
    private var cancelled = false

    init(mode: String) {
        waitsForCancellation = mode == "confirming"
        let review = Self.makeReview(candidate: mode == "candidate", expired: mode == "expired")
        fixtureReview = review
        pendingReview = ["restored", "partial"].contains(mode) ? nil : review
        if mode == "partial" {
            latestResult = AssistantActionResult(
                id: UUID(), reviewID: review.id, localStatus: .added, shortcutNodeID: UUID(),
                members: [.init(node: .channel(7), status: .confirmed), .init(node: .channel(8), status: .notSent)],
                message: "Shortcut added locally. Left confirmed; right not sent after cancellation.",
                submissionID: review.submissionID
            )
        }
    }

    func prepare(_ request: AssistantActionInterpretationRequest,
                 interpretation: AssistantActionInterpretation) async -> AssistantActionPreparation {
        .clarification("UI fixture only; no action preparation.")
    }

    func selectCandidate(reviewID: UUID, candidateID: String) async -> AssistantActionPreparation {
        guard let review = pendingReview, review.id == reviewID,
              let selected = review.candidates.first(where: { $0.id == candidateID }) else {
            return .clarification("Inactive fixture review.")
        }
        let refreshed = Self.makeReview(
            candidate: false, expired: false, selected: selected, submissionID: review.submissionID)
        pendingReview = refreshed
        return .review(refreshed)
    }

    func confirm(reviewID: UUID) async -> AssistantActionResult {
        confirmCalls += 1
        let consumed = pendingReview ?? fixtureReview
        pendingReview = nil
        // Keep the consumed state deterministic until the test cancels or dismisses the sheet.
        if waitsForCancellation {
            while !cancelled && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let result = AssistantActionResult(
            id: UUID(), reviewID: reviewID, localStatus: cancelled ? .notAttempted : .added,
            shortcutNodeID: nil,
            members: consumed.faderChanges.map {
                .init(node: $0.node, status: cancelled ? .notSent : .confirmed)
            },
            message: "UI fixture only. No hardware writes or local graph changes.",
            submissionID: consumed.submissionID
        )
        latestResult = result
        return result
    }

    func cancel() {
        cancelled = true
        pendingReview = nil
    }

    private static func makeReview(
        candidate: Bool, expired: Bool, selected: AssistantActionCandidate? = nil, submissionID: UUID = UUID()
    ) -> AssistantActionReview {
        let session = UUID()
        let mono = [identity(7, label: "AstroLab", source: 4)]
        let pair = [identity(7, label: "Mother-32 L", source: 4), identity(8, label: "Mother-32 R", source: 5)]
        let members = selected?.members ?? (candidate ? mono : pair)
        let pairID = members.count == 2 ? UUID() : nil
        let candidates = [
            AssistantActionCandidate(
                id: "astrolab-7", title: "AstroLab", members: mono, pairStripID: nil, match: .similar
            ),
            AssistantActionCandidate(id: "astrolab-9", title: "Astrolab 2",
                                     members: [identity(9, label: "Astrolab 2", source: 12)],
                                     pairStripID: nil, match: .similar)
        ]
        return AssistantActionReview(
            id: UUID(), submissionID: submissionID, stage: candidate ? .chooseCandidate : .ready,
            targetMention: candidate || selected != nil ? "Astrolab" : "mother32", candidates: candidates,
            selectedCandidateID: selected?.id,
            target: candidate ? nil : .init(sessionID: session, members: members.map {
                .init(identity: $0, position: 0.75, muted: false)
            }, pairStripID: pairID),
            faderChanges: candidate ? [] : members.map {
                .init(node: $0.node, beforePosition: 0.75, afterPosition: selected == nil ? 0.5 : 0.675,
                      beforeMuted: false, afterMuted: false, changesMute: false)
            },
            addsLiveShortcut: true, suggestedAmountDB: selected == nil ? nil : 3,
            expiresAt: Date().addingTimeInterval(expired ? -60 : 300),
            summary: candidate ? "Choose which Astrolab to lower."
                : "Add an existing-channel shortcut and review fader changes.",
            warnings: ["Labels are observations, not proof of attached gear."]
        )
    }

    private static func identity(_ channel: Int, label: String, source: Int) -> AssistantActionChannelIdentity {
        .init(node: .channel(channel), label: label, sourceGroup: "LOCAL", sourceIndex: source, equipmentID: nil)
    }
}
#endif
