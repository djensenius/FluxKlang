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
    var isSelected = false
    var onSelect: () -> Void = {}

    @State private var position = Double(FaderMath.unityPosition)
    @State private var balance = 0.0
    @State private var isBalancing = false
    @State private var isEditing = false

    private var kind: WingNodeKind { strip.node.kind }
    private var index: Int { strip.node.index }
    private var tint: Color { Theme.color(for: kind) }
    private var isStereo: Bool { strip.isStereo }
    private var width: CGFloat { isStereo ? 96 : 78 }

    var body: some View {
        VStack(spacing: 8) {
            readout
            faderRow
            if isStereo { balanceControl }
            muteButton
            labelView
        }
        .frame(width: width)
        .padding(.top, 4)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? tint.opacity(0.12) : .clear)
        }
        .overlay(alignment: .top) {
            Capsule().fill(tint).frame(width: 36, height: 3)
        }
        .overlay(alignment: .topTrailing) {
            if isStereo { stereoBadge }
        }
        .onAppear {
            position = liveCenter
            balance = liveBalance
        }
        .onChange(of: liveCenter) { _, newValue in
            if !isEditing { position = newValue }
        }
        .onChange(of: position) { _, newValue in
            guard isEditing else { return }
            push(position: newValue)
        }
    }

    private var readout: some View {
        Text(FaderMath.label(forPosition: Float(position)))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var faderRow: some View {
        HStack(spacing: 6) {
            VerticalFader(position: $position, isEditing: $isEditing) { newValue in
                push(position: newValue)
            }
            .help(faderHelp)
            MeterView(level: isMuted ? 0 : position)
        }
    }

    private var balanceControl: some View {
        VStack(spacing: 1) {
            Slider(value: $balance, in: -1...1) { editing in
                isBalancing = editing
                if !editing { push(position: position) }
            }
            .controlSize(.mini)
            .onChange(of: balance) { _, _ in
                if isBalancing { push(position: position) }
            }
            Text("Balance")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .help("Trim the left/right balance of this stereo pair")
    }

    private var muteButton: some View {
        Button {
            let muted = !isMuted
            Task { await controller.setMutePair(strip.node, strip.rightNode, muted: muted) }
        } label: {
            Text("MUTE")
                .font(.caption2.weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isMuted ? .red : .gray)
        .help(isMuted ? "Unmute \(label)" : "Mute \(label)")
    }

    private var labelView: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(isSelected ? .bold : .regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width - 8)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
    }

    private var stereoBadge: some View {
        Text("ST")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint)
            .padding(4)
    }

    private func push(position newCenter: Double) {
        Task {
            await controller.setFaderPair(
                strip.node, strip.rightNode,
                position: Float(newCenter), balance: Float(balance)
            )
        }
    }

    private var faderHelp: String {
        isStereo
            ? "Drag to set the pair's level · scroll to adjust · Balance trims L/R"
            : "Drag to set level · double-click for 0 dB · ⌥-drag for fine · scroll to adjust"
    }

    /// Live position of the left (or only) channel.
    private var liveLeft: Double {
        Double(controller.faderPosition(kind, index) ?? FaderMath.unityPosition)
    }

    /// Live position of the right channel (falls back to the left for mono).
    private var liveRight: Double {
        guard let right = strip.rightNode else { return liveLeft }
        return Double(controller.faderPosition(right.kind, right.index) ?? FaderMath.unityPosition)
    }

    /// The ganged centre level — the average of the two channels for a stereo
    /// strip, or just the single channel for a mono strip.
    private var liveCenter: Double {
        isStereo ? (liveLeft + liveRight) / 2 : liveLeft
    }

    /// The live balance trim derived from the two channels (`-1...1`).
    private var liveBalance: Double {
        isStereo ? min(max(liveRight - liveLeft, -1), 1) : 0
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
        FaderStripView(
            controller: .preview(),
            strip: FaderStrip(node: .channel(1), rightNode: .channel(2), customLabel: "OP-1 Field")
        )
        FaderStripView(controller: .preview(), strip: FaderStrip(node: .channel(33)))
        FaderStripView(controller: .preview(), strip: FaderStrip(node: .main(1)))
    }
    .padding()
}
