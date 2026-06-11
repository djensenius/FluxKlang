//
//  FaderStripView.swift
//  FluxKlang
//
//  A single mixer strip: decibel readout, vertical fader and mute. Driven by the
//  WingController so it reflects live changes from the console (or the demo
//  simulator), and pushes the user's moves back via OSC.
//

import SwiftUI

struct FaderStripView: View {
    let controller: WingController
    let kind: WingNodeKind
    let index: Int

    @State private var position = Double(FaderMath.unityPosition)
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 8) {
            Text(FaderMath.label(forPosition: Float(position)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            VerticalFader(position: $position, isEditing: $isEditing)

            Button {
                Task { await controller.setMute(kind, index, muted: !isMuted) }
            } label: {
                Text("MUTE")
                    .font(.caption2.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isMuted ? .red : .gray)

            Text(name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 64)
        }
        .frame(width: 72)
        .onAppear { position = livePosition }
        .onChange(of: livePosition) { _, newValue in
            if !isEditing { position = newValue }
        }
        .onChange(of: position) { _, newValue in
            guard isEditing else { return }
            Task { await controller.setFader(kind, index, position: Float(newValue)) }
        }
    }

    private var livePosition: Double {
        Double(controller.faderPosition(kind, index) ?? FaderMath.unityPosition)
    }

    private var name: String {
        controller.name(kind, index) ?? "\(kind.label) \(index)"
    }

    private var isMuted: Bool {
        controller.isMuted(kind, index) ?? false
    }
}

#Preview {
    HStack(alignment: .top, spacing: 12) {
        FaderStripView(controller: .preview(), kind: .channel, index: 1)
        FaderStripView(controller: .preview(), kind: .channel, index: 9)
        FaderStripView(controller: .preview(), kind: .main, index: 1)
    }
    .padding()
}
