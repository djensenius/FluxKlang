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
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FluxKlang").font(.headline)
                Spacer()
                if appModel.isDemo {
                    Text("DEMO")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
            }

            Text(appModel.wing.connection.statusLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            if appModel.isConnected {
                ForEach(1...4, id: \.self) { channel in
                    QuickFaderRow(controller: appModel.wing, channel: channel)
                }
                Divider()
                Button("Disconnect") {
                    Task { await appModel.disconnect() }
                }
            } else {
                Text("Quick faders appear here once connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await appModel.enterDemoMode() }
                } label: {
                    Label("Enter Demo Mode", systemImage: "play.circle.fill")
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct QuickFaderRow: View {
    let controller: WingController
    let channel: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(controller.name(.channel, channel) ?? "Ch \(channel)")
                .font(.caption)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            Slider(value: position, in: 0...1)
            Text(FaderMath.label(forPosition: controller.faderPosition(.channel, channel) ?? FaderMath.unityPosition))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var position: Binding<Double> {
        Binding(
            get: { Double(controller.faderPosition(.channel, channel) ?? FaderMath.unityPosition) },
            set: { newValue in
                Task { await controller.setFader(.channel, channel, position: Float(newValue)) }
            }
        )
    }
}

#Preview {
    MenuBarMixer()
        .environment(AppModel.preview())
}
#endif
