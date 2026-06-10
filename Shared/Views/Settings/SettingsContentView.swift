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
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status", value: "Not connected")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 240)
        #endif
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsContentView()
}
