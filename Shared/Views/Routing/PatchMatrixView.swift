//
//  PatchMatrixView.swift
//  FluxKlang
//
//  A compact channel × bus send matrix. Tap a cell to toggle that channel's send
//  to a bus; lit cells are on. Syncs live with the WING.
//

import SwiftUI

struct PatchMatrixView: View {
    let controller: WingController

    private let channels = Array(1...16)
    private let buses = Array(1...8)
    private let cell: CGFloat = 34

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Text("")
                        .frame(width: 80)
                    ForEach(buses, id: \.self) { bus in
                        Text("B\(bus)")
                            .font(.caption2)
                            .frame(width: cell)
                    }
                }
                ForEach(channels, id: \.self) { channel in
                    GridRow {
                        Text(controller.name(.channel, channel) ?? "Ch \(channel)")
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 80, alignment: .leading)
                        ForEach(buses, id: \.self) { bus in
                            cellView(channel: channel, bus: bus)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func cellView(channel: Int, bus: Int) -> some View {
        let isOn = controller.isSendOn(.channel, channel, toBus: bus) ?? false
        return Button {
            Task { await controller.setSend(.channel, channel, toBus: bus, on: !isOn) }
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(isOn ? Theme.color(for: .bus) : Color.secondary.opacity(0.15))
                .frame(width: cell, height: cell)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Channel \(channel) → Bus \(bus)")
    }
}

#Preview {
    NavigationStack { PatchMatrixView(controller: .preview()) }
}
