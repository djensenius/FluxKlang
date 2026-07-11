//
//  OutputPatchbayGrid.swift
//  FluxKlang
//
//  The output side of the patchbay: a crosspoint grid of internal sources
//  (columns — a main, bus or matrix within the chosen group) against physical
//  output sockets (rows). Each output carries one source, so lighting a
//  crosspoint patches it and clears the row; tapping a lit cell unpatches the
//  output.
//

import SwiftUI

struct OutputPatchbayGrid: View {
    let controller: WingController

    @State private var group: WingOutputSourceGroup = .main

    private let outputs = Array(1...WingAddress.localOutputCount)
    private var columns: [Int] { columnCount > 0 ? Array(1...columnCount) : [] }

    private var columnCount: Int {
        switch group {
        case .off: return 0
        case .main: return WingNodeKind.main.count
        case .bus: return WingNodeKind.bus.count
        case .matrix: return WingNodeKind.matrix.count
        }
    }

    private var nodeKind: WingNodeKind {
        switch group {
        case .main: return .main
        case .bus: return .bus
        case .matrix, .off: return .matrix
        }
    }

    private var tint: Color { Theme.color(for: nodeKind) }

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
                ForEach(WingOutputSourceGroup.allCases.filter { $0 != .off }, id: \.self) { group in
                    Text(group.label).tag(group)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            Spacer()
            Text("\(group.label) → Output sockets")
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
                ForEach(outputs, id: \.self) { output in
                    row(output)
                }
            }
            .padding()
        }
    }

    private var headerRow: some View {
        HStack(spacing: PatchbayGrid.spacing) {
            Text("Output")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: PatchbayGrid.rowHeader, alignment: .leading)
            ForEach(columns, id: \.self) { index in
                PatchbayGrid.columnHeader("\(index)")
            }
        }
    }

    private func row(_ output: Int) -> some View {
        HStack(spacing: PatchbayGrid.spacing) {
            rowHeader(output)
            ForEach(columns, id: \.self) { index in
                cell(output: output, index: index)
            }
        }
    }

    private func rowHeader(_ output: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(controller.outputName(output) ?? "Output \(output)")
                .font(.caption)
                .lineLimit(1)
            Text(controller.outputSource(output)?.label ?? "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: PatchbayGrid.rowHeader, alignment: .leading)
    }

    private func cell(output: Int, index: Int) -> some View {
        let source = controller.outputSource(output)
        let isOn = source?.group == group && source?.index == index
        return PatchbayGrid.crosspoint(
            isOn: isOn,
            tint: tint,
            help: "\(group.label) \(index) → Output \(output)"
        ) {
            let target: WingOutputSource = isOn ? .none : WingOutputSource(group: group, index: index)
            Task { await controller.setOutputSource(output, to: target) }
        }
    }
}

#Preview {
    NavigationStack { OutputPatchbayGrid(controller: .preview()) }
}
