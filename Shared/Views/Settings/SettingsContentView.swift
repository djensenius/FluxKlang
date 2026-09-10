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
}

#Preview {
    SettingsContentView()
        .environment(AppModel.preview())
}
