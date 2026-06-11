//
//  InputPatchView.swift
//  FluxKlang
//
//  Per-channel input source patching. Each row shows the channel and its current
//  source; a menu picks a new source (transport group + input), pushed to the
//  WING immediately and reflected live.
//

import SwiftUI

struct InputPatchView: View {
    let controller: WingController

    private var channelCount: Int { WingNodeKind.channel.count }

    var body: some View {
        List {
            ForEach(1...channelCount, id: \.self) { channel in
                row(channel)
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }

    private func row(_ channel: Int) -> some View {
        HStack {
            Circle()
                .fill(Theme.color(for: .channel))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.name(.channel, channel) ?? "Channel \(channel)")
                Text("Channel \(channel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sourceMenu(channel)
        }
    }

    private func sourceMenu(_ channel: Int) -> some View {
        Menu {
            Button("None") {
                Task { await controller.setChannelSource(channel, to: .none) }
            }
            ForEach(WingSourceGroup.allCases.filter { $0 != .off }, id: \.self) { group in
                Menu(group.label) {
                    ForEach(1...group.count, id: \.self) { index in
                        Button("\(group.label) \(index)") {
                            Task {
                                await controller.setChannelSource(
                                    channel,
                                    to: WingSource(group: group, index: index)
                                )
                            }
                        }
                    }
                }
            }
        } label: {
            Text(controller.channelSource(channel)?.label ?? "—")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { InputPatchView(controller: .preview()) }
}
