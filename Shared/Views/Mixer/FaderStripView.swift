//
//  FaderStripView.swift
//  FluxKlang
//
//  A single mixer strip: decibel readout, vertical fader with a level meter, and
//  mute. Driven by the WingController so it reflects live changes from the
//  console (or the demo simulator), and pushes the user's moves back via OSC.
//

import SwiftUI

struct FaderStripView: View {
    let controller: WingController
    let strip: FaderStrip

    @State private var position = Double(FaderMath.unityPosition)
    @State private var isEditing = false

    private var kind: WingNodeKind { strip.node.kind }
    private var index: Int { strip.node.index }
    private var tint: Color { Theme.color(for: kind) }

    var body: some View {
        VStack(spacing: 8) {
            Text(FaderMath.label(forPosition: Float(position)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                VerticalFader(position: $position, isEditing: $isEditing)
                MeterView(level: isMuted ? 0 : position)
            }

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

            Text(label)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 70)
        }
        .frame(width: 78)
        .padding(.top, 4)
        .overlay(alignment: .top) {
            Capsule().fill(tint).frame(width: 36, height: 3)
        }
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

    /// User label if set, else the live scribble-strip name, else a default.
    private var label: String {
        if let custom = strip.customLabel, !custom.isEmpty { return custom }
        return controller.name(kind, index) ?? strip.node.defaultLabel
    }

    private var isMuted: Bool {
        controller.isMuted(kind, index) ?? false
    }
}

#Preview {
    HStack(alignment: .top, spacing: 12) {
        FaderStripView(controller: .preview(), strip: FaderStrip(node: .channel(1)))
        FaderStripView(controller: .preview(), strip: FaderStrip(node: .channel(9)))
        FaderStripView(controller: .preview(), strip: FaderStrip(node: .main(1)))
    }
    .padding()
}
