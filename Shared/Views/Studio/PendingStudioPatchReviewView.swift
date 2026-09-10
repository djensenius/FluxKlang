import SwiftUI

struct PendingStudioPatchCard: View {
    let draft: StudioPatchDraft
    let review: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pending Assistant Draft", systemImage: "sparkles.rectangle.stack")
                .font(.headline)
            Text(draft.logicalRoutingSummary.map(\.value).joined(separator: "\n"))
                .foregroundStyle(.secondary)
            HStack {
                Button("Review", action: review)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("assistant.pendingDraft.review")
                Button("Discard", role: .destructive, action: discard)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("assistant.pendingDraft.discard")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PendingStudioPatchReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let draft: StudioPatchDraft
    let accept: () -> Void
    let discard: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Safety") {
                    Label(
                        """
                        Accept only adds valid Studio nodes and wires. \
                        It does not remove routing or write to the WING.
                        """,
                        systemImage: "checkmark.shield"
                    )
                }

                Section("Logical Routing") {
                    ForEach(draft.logicalRoutingSummary, id: \.self) { summary in
                        Text(summary.value)
                    }
                }
                Section("Cable Instructions") {
                    if draft.cableInstructions.isEmpty {
                        Text("No complete configured cable path is available.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(draft.cableInstructions) { instruction in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(instruction.instruction.value)
                            if instruction.usesActiveTemporaryMove {
                                Text("Uses an active Temporary Move instead of Home.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                    }
                }
                if !draft.validation.isEmpty {
                    Section("Validation & Conflicts") {
                        ForEach(draft.validation) { issue in
                            Label(
                                issue.message,
                                systemImage: issue.severity == .error
                                    ? "xmark.octagon.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                        }
                    }
                }
            }
            .navigationTitle("Review Studio Draft")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("assistant.pendingDraft.close")
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Discard", role: .destructive, action: discard)
                        .accessibilityIdentifier("assistant.pendingDraft.discardReview")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept", action: accept)
                        .disabled(draft.hasErrors)
                        .accessibilityIdentifier("assistant.pendingDraft.accept")
                }
            }
        }
    }
}
