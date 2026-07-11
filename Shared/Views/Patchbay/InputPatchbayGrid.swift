//
//  InputPatchbayGrid.swift
//  FluxKlang
//
//  The input side of the patchbay: a crosspoint grid of physical input sources
//  (columns, within a chosen transport group) against channel inputs (rows). Each
//  channel has exactly one source, so lighting a crosspoint patches that source
//  and clears any other in the row; tapping a lit cell unpatches the channel.
//

import SwiftUI

struct InputPatchbayGrid: View {
    let controller: WingController

    @State private var group: WingSourceGroup = .local

    private let channels = Array(1...WingNodeKind.channel.count)
    private var columns: [Int] { group.count > 0 ? Array(1...group.count) : [] }
    private var tint: Color { Theme.color(for: .channel) }

    var body: some View {
        VStack(spacing: 0) {
            groupPicker
            Divider()
            grid
        }
    }

    private var groupPicker: some View {
        HStack {
            Picker("Source", selection: $group) {
                ForEach(WingSourceGroup.allCases.filter { $0 != .off }, id: \.self) { group in
                    Text(group.label).tag(group)
                }
            }
            .pickerStyle(.menu)
            Spacer()
            Text("\(group.label) → Channel inputs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: PatchbayGrid.spacing) {
                headerRow
                ForEach(channels, id: \.self) { channel in
                    row(channel)
                }
            }
            .padding()
        }
    }

    private var headerRow: some View {
        HStack(spacing: PatchbayGrid.spacing) {
            Text("Channel")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: PatchbayGrid.rowHeader, alignment: .leading)
            ForEach(columns, id: \.self) { index in
                PatchbayGrid.columnHeader("\(index)")
            }
        }
    }

    private func row(_ channel: Int) -> some View {
        HStack(spacing: PatchbayGrid.spacing) {
            rowHeader(channel)
            ForEach(columns, id: \.self) { index in
                cell(channel: channel, index: index)
            }
        }
    }

    private func rowHeader(_ channel: Int) -> some View {
        let source = controller.channelSource(channel)
        let offGroup = source.map { $0.group != .off && $0.group != group } ?? false
        return VStack(alignment: .leading, spacing: 1) {
            Text(controller.name(.channel, channel) ?? "Channel \(channel)")
                .font(.caption)
                .lineLimit(1)
            Text(offGroup ? (source?.label ?? "—") : "Ch \(channel)")
                .font(.caption2)
                .foregroundStyle(offGroup ? tint : .secondary)
                .lineLimit(1)
        }
        .frame(width: PatchbayGrid.rowHeader, alignment: .leading)
    }

    private func cell(channel: Int, index: Int) -> some View {
        let source = controller.channelSource(channel)
        let isOn = source?.group == group && source?.index == index
        return PatchbayGrid.crosspoint(
            isOn: isOn,
            tint: tint,
            help: "\(group.label) \(index) → Channel \(channel)"
        ) {
            let target: WingSource = isOn ? .none : WingSource(group: group, index: index)
            Task { await controller.setChannelSource(channel, to: target) }
        }
    }
}

#Preview {
    NavigationStack { InputPatchbayGrid(controller: .preview()) }
}
