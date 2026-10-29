import SwiftUI

/// Saved identity is display-only, including in the session in which the shortcut was created.
struct StudioLiveChannelDetailsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let binding: StudioLiveChannelBinding

    var body: some View {
        NavigationStack {
            Form {
                Section("Existing-channel shortcut") {
                    Label("Unverified saved observation", systemImage: "link.badge.plus")
                        .accessibilityIdentifier("studio.liveShortcut.unverified")
                    Text("""
                    This is a shortcut to an existing WING channel, not Equipment or an audio \
                    routing node. Its saved label does not prove a current connection or audible \
                    sound.
                    """)
                    Text("""
                    No audio ports, cables, buses or routing are created. Moving or removing this \
                    shortcut changes only the canvas.
                    """)
                }
                Section(binding.pairStripID == nil ? "Saved channel evidence" : "Saved stereo pair · left / right") {
                    ForEach(Array(binding.members.enumerated()), id: \.offset) { index, member in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("""
                            \(AssistantActionDisplay.side(index: index, count: binding.members.count))\
                            Channel \(member.channel) · “\(member.label)”
                            """)
                                .font(.subheadline.weight(.semibold))
                            Text(AssistantActionDisplay.source(group: member.sourceGroup, index: member.sourceIndex))
                            Text(AssistantActionDisplay.linkage(member.equipmentID))
                        }
                    }
                    LabeledContent("Observed", value: binding.observedAt.formatted())
                    Text("Observed session: \(binding.observedSessionID.uuidString)")
                        .font(.caption.monospaced())
                    Text("""
                    Saved evidence only. Restoring, syncing, or reconnecting never authorizes \
                    control of another session.
                    """)
                        .font(.caption)
                }
                Section("Request a fresh review") {
                    Text(connectionExplanation)
                    Button("Ask Assistant About This Shortcut") {
                        appModel.assistantChat.suggestedPrompt = inspectionPrompt
                        appModel.section = .assistant
                        dismiss()
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("studio.liveShortcut.askAssistant")
                }
            }
            .navigationTitle("Live Channel Shortcut")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionExplanation: String {
        if appModel.isConnected {
            return """
            A WING connection is available, but this shortcut has not been revalidated. \
            Ask Assistant and select fresh live evidence before confirming a change.
            """
        }
        return """
        Offline. Connect to WING, then ask Assistant to review the intended channel. \
        This saved shortcut cannot send changes.
        """
    }

    private var inspectionPrompt: String {
        let members = binding.members.map { "channel \($0.channel) labelled “\($0.label)”" }.joined(separator: " and ")
        return """
        Explain this unverified saved live-channel shortcut: \(members). \
        How can I review its current identity safely? Do not change any values.
        """
    }
}
