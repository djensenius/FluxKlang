import SwiftUI

struct AssistantView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            #if os(macOS)
            regularLayout
            #else
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
            #endif
        }
        .navigationTitle("Assistant")
        .task {
            await appModel.assistantChat.load()
            if let prompt = appModel.assistantChat.suggestedPrompt {
                appModel.assistantChat.submitSuggestedPrompt(prompt)
            }
        }
    }

    private var compactLayout: some View {
        AssistantConversationDetail()
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    AssistantHistoryMenu()
                }
            }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            AssistantHistoryList()
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            Divider()
            AssistantConversationDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AssistantHistoryList: View {
    @Environment(AppModel.self) private var appModel
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var confirmsClearAll = false

    var body: some View {
        @Bindable var chat = appModel.assistantChat
        List(selection: $chat.selectedConversationID) {
            ForEach(chat.conversations) { conversation in
                Text(conversation.title)
                    .lineLimit(1)
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Rename") {
                            renameID = conversation.id
                            renameText = conversation.title
                        }
                        Button("Delete", role: .destructive) {
                            chat.deleteConversation(id: conversation.id)
                        }
                        .accessibilityIdentifier("assistant.history.delete.\(conversation.id.uuidString)")
                    }
            }
        }
        .overlay {
            if chat.conversations.isEmpty {
                ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    chat.newConversation()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                Spacer()
                Menu {
                    Button("Clear All", role: .destructive) {
                        confirmsClearAll = true
                    }
                    .disabled(chat.conversations.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding()
            .background(.bar)
        }
        .alert("Rename Conversation", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameID {
                    chat.renameConversation(id: renameID, to: renameText)
                }
            }
        }
        .confirmationDialog(
            "Delete all assistant conversations?",
            isPresented: $confirmsClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { chat.clearAll() }
        } message: {
            Text("This propagates deletions to private iCloud when CloudKit is available.")
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameID != nil },
            set: { if !$0 { renameID = nil } }
        )
    }
}

private struct AssistantHistoryMenu: View {
    @Environment(AppModel.self) private var appModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Conversation History", systemImage: "clock.arrow.circlepath")
        }
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                AssistantHistoryList()
                    .navigationTitle("Conversation History")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented = false }
                        }
                    }
            }
            .environment(appModel)
        }
    }
}

private struct AssistantConversationDetail: View {
    @Environment(AppModel.self) private var appModel
    @State private var voice = AssistantVoiceController()
    @State private var showsWiringForm = false

    var body: some View {
        @Bindable var chat = appModel.assistantChat
        VStack(spacing: 0) {
            AssistantAvailabilityBanner()
            if let conversation = chat.selectedConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            privacyCopy
                            ForEach(conversation.messages) { message in
                                AssistantMessageView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: conversation.messages.count) {
                        if let id = conversation.messages.last?.id {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }
            } else {
                emptyState
            }
            Divider()
            suggestedPrompts
            composer
        }
        .sheet(isPresented: $showsWiringForm) {
            AssistantWiringForm()
        }
        .onChange(of: voice.transcript) { _, transcript in
            if !transcript.isEmpty {
                chat.composer = transcript
            }
        }
        .onChange(of: chat.suggestedPrompt) { _, prompt in
            if let prompt {
                chat.submitSuggestedPrompt(prompt)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ask FluxKlang", systemImage: "sparkles")
        } description: {
            Text("Get grounded help, inspect wiring, or create a review-only Studio draft.")
        } actions: {
            Button("Start Conversation") { appModel.assistantChat.newConversation() }
        }
        .frame(maxHeight: .infinity)
    }

    private var privacyCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("""
                Generation and transcription run on device. Visible conversation text and card references can sync \
                through your private iCloud database. Microphone audio is never retained.
                """)
            } icon: {
                Image(systemName: "hand.raised.fill")
            }
            ForEach(appModel.assistantChat.persistenceDiagnostics, id: \.self) { diagnostic in
                Label(diagnostic, systemImage: "icloud.slash")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var suggestedPrompts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                promptButton("Explain this screen")
                promptButton("Show wiring conflicts")
                promptButton("List active moves")
                Button("Create wiring draft") { showsWiringForm = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func promptButton(_ prompt: String) -> some View {
        Button(prompt) {
            appModel.assistantChat.submitSuggestedPrompt(prompt)
        }
        .buttonStyle(.bordered)
    }

    private var composer: some View {
        @Bindable var chat = appModel.assistantChat
        return VStack(spacing: 8) {
            if case .failed(let message) = voice.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about FluxKlang", text: $chat.composer, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Assistant message")
                    .accessibilityIdentifier("assistant.composer")
                    .onSubmit {
                        chat.send(context: appModel.assistantToolContext())
                    }
                Button {
                    toggleVoice()
                } label: {
                    Image(systemName: voice.state == .listening ? "stop.circle.fill" : "mic.circle")
                }
                .accessibilityLabel(voice.state == .listening ? "Finish dictation" : "Start dictation")
                .accessibilityIdentifier("assistant.mic")
                if voice.state == .listening || voice.state == .preparingModel {
                    Button(role: .cancel) { voice.cancel() } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .accessibilityLabel("Cancel dictation")
                }
                if chat.isStreaming {
                    Button(role: .cancel) { chat.cancel() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .accessibilityLabel("Cancel response")
                    .accessibilityIdentifier("assistant.cancel")
                } else {
                    Button {
                        chat.send(context: appModel.assistantToolContext())
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .disabled(chat.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("assistant.send")
                }
            }
            Toggle("Speak replies", isOn: $chat.spokenRepliesEnabled)
                .font(.caption)
                .accessibilityIdentifier("assistant.spokenReplies")
        }
        .padding()
        .background(.bar)
    }

    private func toggleVoice() {
        if voice.state == .listening {
            voice.finish()
        } else {
            voice.start()
        }
    }
}

private struct AssistantAvailabilityBanner: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let availability = appModel.assistantChat.modelAvailability
        HStack {
            Image(systemName: availability == .ready ? "apple.intelligence" : "info.circle")
            Text(availability.title)
            Spacer()
            if availability.usesFallback {
                Text("Using grounded fallback")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Assistant availability")
        .accessibilityValue(
            availability.usesFallback
                ? "\(availability.title). Using grounded fallback."
                : availability.title
        )
        .accessibilityIdentifier("assistant.availability")
    }
}

private struct AssistantMessageView: View {
    @Environment(AppModel.self) private var appModel
    let message: AssistantMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in
                AssistantCardView(card: card)
            }
            if message.state == .streaming {
                ProgressView()
                    .controlSize(.small)
            } else if message.state == .cancelled {
                Label("Response cancelled", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if message.state == .failed {
                Button("Retry") {
                    appModel.assistantChat.retry(
                        messageID: message.id,
                        context: appModel.assistantToolContext()
                    )
                }
                .accessibilityIdentifier("assistant.retry")
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }
}

private struct AssistantCardView: View {
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
                    ForEach(summary, id: \.self, content: Text.init)
                    ForEach(cables, id: \.self) {
                        Label($0, systemImage: "arrow.right")
                    }
                }
            case .conflicts(let issues):
                AssistantInlineCard(title: "Conflicts", systemImage: "exclamationmark.triangle") {
                    if issues.isEmpty {
                        Text("No current conflicts.")
                    } else {
                        ForEach(issues, id: \.self) {
                            Label($0, systemImage: "exclamationmark.circle")
                        }
                    }
                }
            case .moves(let moves):
                AssistantInlineCard(title: "Temporary Moves", systemImage: "arrow.triangle.swap") {
                    ForEach(moves, id: \.self, content: Text.init)
                }
            case .pendingDraft(_, let summary, let hasErrors):
                AssistantInlineCard(title: "Pending Draft", systemImage: "doc.badge.clock") {
                    Text(summary)
                    if hasErrors {
                        Label("Resolve validation errors before accepting.", systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                    }
                    Button("Review Draft") {
                        appModel.assistant.navigationTarget = .reviewPendingDraft
                    }
                    .accessibilityIdentifier("assistant.draftReviewCard")
                }
            }
        }
    }
}

private struct AssistantInlineCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

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
