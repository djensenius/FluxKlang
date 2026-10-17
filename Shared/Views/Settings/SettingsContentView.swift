//
//  SettingsContentView.swift
//  FluxKlang
//
//  Shared preferences content. On macOS it is hosted by the Settings scene
//  (⌘,); on iOS it is presented from the Connection section. Placeholder until
//  the connection / OSC settings land.
//

import SwiftUI

struct SettingsContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingStudioConnections = false
    @State private var copilotToken = ""

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status", value: appModel.wing.connection.statusLabel)
                if let host = appModel.wing.host {
                    LabeledContent("Host", value: host)
                }
                LabeledContent("OSC port", value: String(appModel.wing.port))
                if let last = appModel.lastHost {
                    LabeledContent("Last WING", value: last)
                }
            }

            Section("Studio") {
                Button {
                    isShowingStudioConnections = true
                } label: {
                    LabeledContent {
                        Text(connectionCount.formatted())
                    } label: {
                        Label("Studio Connections", systemImage: "cable.connector")
                    }
                }
                .accessibilityIdentifier("settings-studio-connections")
            }

            Section("Mixer") {
                LabeledContent("Fader strips", value: String(appModel.faderLayout.layout.strips.count))
                Button("Reset faders to standard layout") {
                    appModel.faderLayout.resetToStandard()
                }
            }

            Section("Launch Control XL 3") {
                Picker("USB mode", selection: launchControlMode) {
                    ForEach(LaunchControlXLMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                LabeledContent("MIDI source", value: appModel.launchControlXL.status.label)
                LabeledContent("Fader bank", value: String(appModel.launchControlXL.bank + 1))
                if let action = appModel.launchControlXL.lastAction {
                    LabeledContent("Last control", value: actionLabel(action))
                }
                Text(
                    "Use Default Mode 16. With your DIN cable connected to the WING, use Monitor so the WING "
                        + "handles MIDI and FluxKlang follows its OSC updates. Use Control through FluxKlang only "
                        + "after disabling the direct WING MIDI mapping to avoid duplicate actions."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Mapping file: Application Support/FluxKlang/launch-control-xl.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Assistant") {
                Picker("Provider", selection: assistantProvider) {
                    ForEach(AssistantProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                if appModel.assistantProviderSettings.provider == .githubCopilot {
                    TextField("Model", text: copilotModel)
                    SecureField("GitHub token", text: $copilotToken)
                    HStack {
                        Button("Save token") {
                            appModel.assistantProviderSettings.saveCopilotToken(copilotToken)
                            copilotToken = ""
                            refreshAssistantAvailability()
                        }
                        .disabled(copilotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if appModel.assistantProviderSettings.hasCopilotToken {
                            Button("Remove token", role: .destructive) {
                                appModel.assistantProviderSettings.removeCopilotToken()
                                refreshAssistantAvailability()
                            }
                        }
                    }
                    LabeledContent(
                        "Configuration",
                        value: appModel.assistantProviderSettings.hasCopilotToken
                            ? "Token stored in Keychain"
                            : "Token required"
                    )
                    if let error = appModel.assistantProviderSettings.credentialError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    Text(
                        "Copilot receives your prompt and the FluxKlang tool results needed to answer it. "
                            + "The token remains in this device's Keychain and is never stored in iCloud. "
                            + "Copilot can inspect state or create a review-only draft, but cannot write to WING."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("App Icon") {
                AppIconPicker()
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
        .navigationTitle("Settings")
        .sheet(isPresented: $isShowingStudioConnections) {
            NavigationStack {
                StudioConnectionsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingStudioConnections = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 720)
            #endif
        }
    }

    private var connectionCount: Int {
        let home = appModel.studioConnections.connections.home
        return home.inputs.count + home.outputs.count
    }

    private var launchControlMode: Binding<LaunchControlXLMode> {
        Binding(
            get: { appModel.launchControlXL.configuration.mode },
            set: { mode in
                Task { await appModel.launchControlXL.setMode(mode) }
            }
        )
    }

    private var assistantProvider: Binding<AssistantProvider> {
        Binding(
            get: { appModel.assistantProviderSettings.provider },
            set: { provider in
                appModel.assistantProviderSettings.provider = provider
                refreshAssistantAvailability()
            }
        )
    }

    private var copilotModel: Binding<String> {
        Binding(
            get: { appModel.assistantProviderSettings.copilotModel },
            set: { appModel.assistantProviderSettings.copilotModel = $0 }
        )
    }

    private func refreshAssistantAvailability() {
        Task { await appModel.assistantChat.refreshAvailability() }
    }

    private func actionLabel(_ action: LaunchControlXLAction) -> String {
        switch action {
        case .fader(let slot, _): "Fader \(slot + 1)"
        case .panOrBalance(let slot, _): "Pan/Balance \(slot + 1)"
        case .select(let slot): "Select \(slot + 1)"
        case .toggleMute(let slot): "Mute \(slot + 1)"
        case .moveBank(let delta): delta < 0 ? "Previous bank" : "Next bank"
        }
    }
}

#Preview {
    SettingsContentView()
        .environment(AppModel.preview())
}
