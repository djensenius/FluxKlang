//
//  AddSpatialSourceView.swift
//  FluxKlang
//
//  Sheet for adding an instrument to the spatial field. A source is mono (one
//  WING channel) or stereo (two arbitrary channels, which need not be adjacent).
//

import SwiftUI

struct AddSpatialSourceView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var mode: SpatialSourceMode = .mono
    @State private var leftChannel = 1
    @State private var rightChannel = 2
    @State private var width = 0.5

    private let channels = Array(1...WingNodeKind.channel.count)

    var body: some View {
        NavigationStack {
            Form {
                Section("Instrument") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $mode) {
                        Text("Mono").tag(SpatialSourceMode.mono)
                        Text("Stereo").tag(SpatialSourceMode.stereo)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Channels") {
                    channelPicker(mode == .mono ? "Channel" : "Left", selection: $leftChannel)
                    if mode == .stereo {
                        channelPicker("Right", selection: $rightChannel)
                        HStack {
                            Text("Width")
                            Slider(value: $width, in: 0...1)
                            Text(String(format: "%.0f%%", width * 100))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Instrument")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(isInvalid)
                }
            }
            .onAppear { if name.isEmpty { name = channelName(leftChannel) } }
        }
        .frame(minWidth: 360, minHeight: 320)
    }

    private func channelPicker(_ label: String, selection: Binding<Int>) -> some View {
        Picker(label, selection: selection) {
            ForEach(channels, id: \.self) { channel in
                Text(channelName(channel)).tag(channel)
            }
        }
    }

    private func channelName(_ channel: Int) -> String {
        appModel.wing.name(.channel, channel) ?? "Channel \(channel)"
    }

    private var isInvalid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return mode == .stereo && leftChannel == rightChannel
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = SpatialSource(
            name: trimmed.isEmpty ? channelName(leftChannel) : trimmed,
            mode: mode,
            left: .channel(leftChannel),
            right: mode == .stereo ? .channel(rightChannel) : nil,
            width: width
        )
        appModel.spatial.addSource(source)
        Task { await appModel.applyPlacement(source) }
        dismiss()
    }
}

#Preview {
    AddSpatialSourceView(appModel: .preview())
}
