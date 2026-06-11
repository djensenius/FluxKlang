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

            Section("Mixer") {
                LabeledContent("Fader strips", value: String(appModel.faderLayout.layout.strips.count))
                Button("Reset faders to standard layout") {
                    appModel.faderLayout.resetToStandard()
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsContentView()
        .environment(AppModel.preview())
}
