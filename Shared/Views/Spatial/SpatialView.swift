//
//  SpatialView.swift
//  FluxKlang
//
//  Surround / spatial mixing. A segmented control switches between placing
//  instruments in the 2D field (which drives per-channel bus sends via DBAP) and
//  controlling the stereo-pair speaker volumes. Speakers and instruments are
//  fully configurable for mono or stereo sources across a 4+ speaker array.
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
    @State private var selection: SpatialSource.ID?
    @State private var showingAdd = false
    @State private var showingConfig = false

    private var store: SpatialStore { appModel.spatial }
    private var selectedSource: SpatialSource? {
        store.sources.first { $0.id == selection }
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
        .sheet(isPresented: $showingAdd) { AddSpatialSourceView(appModel: appModel) }
        .sheet(isPresented: $showingConfig) { SpeakerConfigView(appModel: appModel) }
    }

    @ViewBuilder
    private var placeContent: some View {
        SpatialPadView(appModel: appModel, selection: $selection)
        if let source = selectedSource {
            SelectedSourceBar(appModel: appModel, source: source) { selection = nil }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showingAdd = true } label: {
                Label("Add Instrument", systemImage: "plus")
            }
            .help("Add an instrument to the field")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await appModel.applyAllPlacements() } } label: {
                Label("Apply", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("Re-send all placements to the WING")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showingConfig = true } label: {
                Label("Configure Speakers", systemImage: "hifispeaker.2")
            }
            .help("Map speakers to buses and positions")
        }
    }
}

/// Controls for the instrument currently selected on the pad.
private struct SelectedSourceBar: View {
    let appModel: AppModel
    let source: SpatialSource
    var onClose: () -> Void

    private var store: SpatialStore { appModel.spatial }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button(role: .destructive) {
                    store.removeSource(source.id)
                    onClose()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            Text(channelSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if source.isStereo {
                HStack {
                    Text("Width").frame(width: 60, alignment: .leading)
                    Slider(value: widthBinding, in: 0...1)
                    Text(String(format: "%.0f%%", source.width * 100))
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

    private var channelSummary: String {
        if source.isStereo, let right = source.right {
            return "Stereo · L \(channelName(source.left)) · R \(channelName(right))"
        }
        return "Mono · \(channelName(source.left))"
    }

    private func channelName(_ node: WingNodeRef) -> String {
        appModel.wing.name(node.kind, node.index) ?? node.defaultLabel
    }

    private var nameBinding: Binding<String> {
        Binding(get: { source.name }, set: { store.rename(source.id, to: $0) })
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { source.width },
            set: { newValue in
                store.updateWidth(source.id, to: newValue)
                var moved = source
                moved.width = newValue
                Task { await appModel.applyPlacement(moved) }
            }
        )
    }
}

#Preview {
    let model = AppModel.preview()
    return NavigationStack { SpatialView() }
        .environment(model)
        .task { await model.spatial.load() }
}
