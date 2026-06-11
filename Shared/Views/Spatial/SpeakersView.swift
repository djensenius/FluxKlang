//
//  SpeakersView.swift
//  FluxKlang
//
//  Stereo-pair speaker volume. Each pair drives two WING bus master faders
//  together, with a balance trim and a linked mute. Levels reflect the console
//  live (including changes from other controllers).
//

import SwiftUI

struct SpeakersView: View {
    let appModel: AppModel

    private var pairs: [SpeakerPair] { appModel.spatial.array.pairs }

    var body: some View {
        Group {
            if pairs.isEmpty {
                ContentUnavailableView(
                    "No Speaker Pairs",
                    systemImage: "hifispeaker.2",
                    description: Text("Add stereo pairs in the speaker configuration.")
                )
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(pairs) { pair in
                            SpeakerPairStripView(appModel: appModel, pair: pair)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Speakers")
    }
}

private struct SpeakerPairStripView: View {
    let appModel: AppModel
    let pair: SpeakerPair

    @State private var level = Double(FaderMath.unityPosition)
    @State private var balance = 0.0
    @State private var isEditing = false

    private var controller: WingController { appModel.wing }
    private var array: SpeakerArray { appModel.spatial.array }
    private var tint: Color { Theme.color(for: .bus) }

    var body: some View {
        VStack(spacing: 8) {
            Text(pair.name).font(.headline)
            Text(FaderMath.label(forPosition: Float(level)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            VerticalFader(position: $level, isEditing: $isEditing) { _ in push() }
                .tint(tint)
                .frame(height: 220)
                .help("Drag to set both speakers · double-click for 0 dB · scroll to adjust")

            balanceControl
            muteButton
            speakerLabels
        }
        .frame(width: 150)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08))
        }
        .overlay(alignment: .top) {
            Capsule().fill(tint).frame(width: 44, height: 3)
        }
        .onAppear(perform: sync)
        .onChange(of: liveLeft) { _, _ in if !isEditing { sync() } }
        .onChange(of: liveRight) { _, _ in if !isEditing { sync() } }
        .onChange(of: level) { _, _ in if isEditing { push() } }
        .onChange(of: balance) { _, _ in push() }
    }

    private var balanceControl: some View {
        VStack(spacing: 2) {
            Slider(value: $balance, in: -1...1)
                .controlSize(.small)
            Text("Balance \(balanceLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
    }

    private var muteButton: some View {
        Button {
            Task { await appModel.setSpeakerPairMuted(pair, muted: !isMuted) }
        } label: {
            Text(isMuted ? "MUTED" : "MUTE")
                .font(.caption2.weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isMuted ? .red : .gray)
        .padding(.horizontal, 8)
    }

    private var speakerLabels: some View {
        HStack {
            speakerName(pair.left)
            Spacer()
            speakerName(pair.right)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private func speakerName(_ identifier: Speaker.ID) -> some View {
        Text(array.speaker(identifier)?.name ?? "—")
            .lineLimit(1)
    }

    // MARK: - Live sync

    private func livePosition(_ identifier: Speaker.ID) -> Double {
        guard let speaker = array.speaker(identifier),
              let position = controller.faderPosition(speaker.node.kind, speaker.node.index) else {
            return Double(FaderMath.unityPosition)
        }
        return Double(position)
    }

    private var liveLeft: Double { livePosition(pair.left) }
    private var liveRight: Double { livePosition(pair.right) }

    private func sync() {
        let left = liveLeft
        let right = liveRight
        level = (left + right) / 2
        balance = min(max(right - left, -1), 1)
    }

    private func push() {
        Task { await appModel.setSpeakerPair(pair, position: Float(level), balance: Float(balance)) }
    }

    private var balanceLabel: String {
        if abs(balance) < 0.01 { return "C" }
        return balance < 0 ? String(format: "L%.0f", -balance * 100) : String(format: "R%.0f", balance * 100)
    }

    private var isMuted: Bool {
        guard let left = array.speaker(pair.left), let right = array.speaker(pair.right) else { return false }
        let leftMuted = controller.isMuted(left.node.kind, left.node.index) ?? false
        let rightMuted = controller.isMuted(right.node.kind, right.node.index) ?? false
        return leftMuted || rightMuted
    }
}

#Preview {
    let model = AppModel.preview()
    return NavigationStack { SpeakersView(appModel: model) }
        .task { await model.spatial.load() }
}
