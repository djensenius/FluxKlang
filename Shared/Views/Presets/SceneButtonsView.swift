//
//  SceneButtonsView.swift
//  FluxKlang
//
//  A grid of one-tap scene buttons that recall presets. Used at the top of the
//  Presets screen and reusable elsewhere (e.g. the Mac menu bar).
//

import SwiftUI

struct SceneButtonsView: View {
    let presets: [Preset]
    let onRecall: (Preset) -> Void
    var isEnabled = true

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(presets) { preset in
                Button { onRecall(preset) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.title3)
                        Text(preset.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(!isEnabled)
            }
        }
    }
}

#Preview {
    SceneButtonsView(
        presets: [
            Preset(name: "Soundcheck"),
            Preset(name: "Live Set"),
            Preset(name: "Ambient")
        ],
        onRecall: { _ in }
    )
    .padding()
}
