//
//  MenuBarMixer.swift
//  FluxKlang
//
//  Menu-bar quick-mixer content. A compact set of fader / mute controls and a
//  connection toggle will live here so common moves never require opening the
//  main window. Placeholder for now.
//

#if os(macOS)
import SwiftUI

struct MenuBarMixer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FluxKlang")
                .font(.headline)
            Text("Not connected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            Text("Quick faders appear here once connected.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280)
    }
}
#endif
