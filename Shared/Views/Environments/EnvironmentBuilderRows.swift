//
//  EnvironmentBuilderRows.swift
//  FluxKlang
//
//  Small rows/cards used by the simple Environment builder.
//

import SwiftUI

struct EnvironmentSummary: View {
    let effects: [Effect]
    let voices: [EnvironmentVoice]

    var body: some View {
        HStack(spacing: 16) {
            summary("\(effects.count)", effects.count == 1 ? "effect" : "effects", "waveform.path.ecg")
            summary("\(sendCount)", sendCount == 1 ? "send" : "sends", "arrow.triangle.branch")
            summary("\(voices.count)", voices.count == 1 ? "voice" : "voices", "hifispeaker")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private var sendCount: Int {
        effects.reduce(0) { $0 + $1.sourceInstruments.count }
    }

    private func summary(_ value: String, _ label: String, _ systemImage: String) -> some View {
        Label {
            Text("\(value) \(label)")
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

struct SimpleEffectCard: View {
    let effect: Effect
    let allocation: EffectRouting.Allocation?
    let sourceNames: [String]
    let destinationName: String?
    var onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(effect.name, systemImage: "waveform.path.ecg")
                        .font(.headline)
                    Spacer()
                    Text(effect.isStereo ? "Stereo" : "Mono")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(sourceSummary)
                    .font(.subheadline)
                    .foregroundStyle(sourceNames.isEmpty ? .secondary : .primary)
                Label(routeSummary, systemImage: "cable.connector")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var sourceSummary: String {
        if sourceNames.isEmpty { return "No instruments feeding this yet" }
        return sourceNames.joined(separator: ", ")
    }

    private var routeSummary: String {
        let destination = destinationName ?? "Main"
        guard let allocation, !allocation.buses.isEmpty else {
            return "No free bus · returns to \(destination)"
        }
        let bus = label("Bus", allocation.buses)
        let returns = label("Return", allocation.returnChannels)
        return "\(bus) · \(returns) · to \(destination)"
    }

    private func label(_ prefix: String, _ values: [Int]) -> String {
        prefix + " " + values.map(String.init).joined(separator: "/")
    }
}

struct InstrumentSendRow: View {
    let assignment: Equipment.ChannelAssignment
    let effects: [Effect]
    let isSending: (Effect) -> Bool
    let toggle: (Effect, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(assignment.equipment.name, systemImage: "pianokeys")
                    .font(.headline)
                Spacer()
                Text(channelLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(effects) { effect in
                        SendChip(title: effect.name, isOn: isSending(effect)) {
                            toggle(effect, !isSending(effect))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var channelLabel: String {
        if let right = assignment.rightChannel {
            return "Ch \(assignment.leftChannel)/\(right)"
        }
        return "Ch \(assignment.leftChannel)"
    }
}

private struct SendChip: View {
    let title: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
}

struct VoiceRow: View {
    let voice: EnvironmentVoice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: voice.kind == .source ? "pianokeys" : "waveform")
                .foregroundStyle(voice.kind == .source ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(.subheadline)
                if voice.isShared {
                    Text(voice.sourcesLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !voice.channels.isEmpty {
                Text(channelLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var channelLabel: String {
        let channels = voice.channels.map(String.init).joined(separator: "/")
        let prefix = voice.kind == .source ? "Ch" : "Rtn"
        return "\(prefix) \(channels)"
    }
}
