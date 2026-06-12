//
//  SpatialView.swift
//  FluxKlang
//
//  Surround / spatial mixing, driven by the active environment. A segmented
//  control switches between placing the environment's voices in the 2D field
//  (which drives per-channel speaker-bus sends via DBAP) and controlling the
//  stereo-pair speaker volumes. The placeable voices are derived from the
//  environment's routing — dry instruments and shared effect returns — and their
//  positions are saved per environment, so switching environments recalls the
//  whole stage. Surround sends are additive: the dry/return mix still feeds the
//  main, so placement coexists with it.
//

import SwiftUI

struct SpatialView: View {
    @Environment(AppModel.self) private var appModel

    private enum Mode: String, CaseIterable, Identifiable {
        case place = "Place"
        case speakers = "Speakers"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .place
    @State private var selection: String?
    @State private var showingConfig = false

    private var placedVoices: [PlacedVoice] { appModel.placedVoices() }
    private var selectedVoice: PlacedVoice? {
        placedVoices.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            switch mode {
            case .place:
                placeContent
            case .speakers:
                SpeakersView(appModel: appModel)
            }
        }
        .navigationTitle("Spatial")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingConfig) { SpeakerConfigView(appModel: appModel) }
    }

    @ViewBuilder
    private var placeContent: some View {
        if appModel.environments.active == nil {
            noEnvironmentState
        } else if placedVoices.isEmpty {
            noVoicesState
        } else {
            SpatialPadView(appModel: appModel, voices: placedVoices, selection: $selection)
            if let voice = selectedVoice {
                SelectedVoiceBar(appModel: appModel, placed: voice) { selection = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var noEnvironmentState: some View {
        ContentUnavailableView {
            Label("No Environment", systemImage: "rectangle.3.group")
        } description: {
            Text("""
            Create an environment and add effects in the Environments tab, then come back to place its voices \
            in space.
            """)
        }
    }

    private var noVoicesState: some View {
        ContentUnavailableView {
            Label("Nothing to place yet", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("""
            “\(appModel.environments.active?.name ?? "This environment")” has no voices yet. Add effects and pick \
            the instruments that feed them in the Environments tab — each instrument and each effect return becomes \
            a voice you can place here.
            """)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await appModel.applyAllPlacements() } } label: {
                Label("Apply", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(!appModel.isConnected || appModel.environmentSpatialSettings().isEmpty)
            .help("Re-send every placed voice to the WING")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showingConfig = true } label: {
                Label("Configure Speakers", systemImage: "hifispeaker.2")
            }
            .help("Map speakers to buses and positions")
        }
    }
}

/// Controls for the voice currently selected on the pad.
private struct SelectedVoiceBar: View {
    let appModel: AppModel
    let placed: PlacedVoice
    var onClose: () -> Void

    private var store: EnvironmentStore { appModel.environments }
    private var voice: EnvironmentVoice { placed.voice }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if placed.isPlaced {
                    Button(role: .destructive) {
                        store.clearPlacement(voice.id)
                        onClose()
                    } label: {
                        Label("Remove", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .help("Take this voice out of the spatial field")
                }
            }
            if voice.isShared {
                Label("Shared effect — its sources move together.", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if voice.isStereo {
                HStack {
                    Text("Width").frame(width: 60, alignment: .leading)
                    Slider(value: widthBinding, in: 0...1)
                    Text(String(format: "%.0f%%", placed.width * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding([.horizontal, .bottom])
    }

    private var detail: String {
        let kind = voice.kind == .source ? "Instrument" : "Effect return"
        let channels = voice.channels.map(String.init).joined(separator: "/")
        let label = voice.isShared ? voice.sourcesLabel : channelDescription(channels)
        return "\(kind) · \(label)"
    }

    private func channelDescription(_ channels: String) -> String {
        let noun = voice.isStereo ? "Channels" : "Channel"
        return "\(noun) \(channels)"
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { placed.width },
            set: { newValue in
                store.setVoiceWidth(voice.id, to: newValue)
                var moved = placed
                moved.width = newValue
                moved.isPlaced = true
                Task { await appModel.applyVoicePlacement(moved) }
            }
        )
    }
}

#Preview {
    let model = AppModel.preview()
    return NavigationStack { SpatialView() }
        .environment(model)
        .task {
            await model.equipment.load()
            await model.environments.load()
            await model.spatial.load()
        }
}
