//
//  OutputRoutingView.swift
//  FluxKlang
//
//  Output routing in the WING send model: choose a channel, then assign it to
//  the main bus(es) and toggle / level its bus sends. Everything syncs live.
//

import SwiftUI

struct OutputRoutingView: View {
    let controller: WingController

    @State private var channel = 1

    private var mainCount: Int { WingNodeKind.main.count }
    private var busCount: Int { WingNodeKind.bus.count }

    var body: some View {
        Form {
            Section {
                Picker("Channel", selection: $channel) {
                    ForEach(1...WingNodeKind.channel.count, id: \.self) { index in
                        Text(controller.name(.channel, index) ?? "Channel \(index)").tag(index)
                    }
                }
            }

            Section("Main Assign") {
                ForEach(1...mainCount, id: \.self) { main in
                    Toggle(controller.name(.main, main) ?? "Main \(main)", isOn: mainBinding(main))
                }
            }

            Section("Bus Sends") {
                ForEach(1...busCount, id: \.self) { bus in
                    busSendRow(bus)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func busSendRow(_ bus: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(controller.name(.bus, bus) ?? "Bus \(bus)", isOn: sendBinding(bus))
            if controller.isSendOn(.channel, channel, toBus: bus) == true {
                HStack {
                    Text("Level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: sendLevelBinding(bus), in: -60...10)
                    Text(String(format: "%+.0f dB", controller.sendLevel(.channel, channel, toBus: bus) ?? 0))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    private func mainBinding(_ main: Int) -> Binding<Bool> {
        Binding(
            get: { controller.isMainAssigned(.channel, channel, toMain: main) ?? false },
            set: { newValue in
                Task { await controller.setMainAssign(.channel, channel, toMain: main, on: newValue) }
            }
        )
    }

    private func sendBinding(_ bus: Int) -> Binding<Bool> {
        Binding(
            get: { controller.isSendOn(.channel, channel, toBus: bus) ?? false },
            set: { newValue in
                Task { await controller.setSend(.channel, channel, toBus: bus, on: newValue) }
            }
        )
    }

    private func sendLevelBinding(_ bus: Int) -> Binding<Double> {
        Binding(
            get: { Double(controller.sendLevel(.channel, channel, toBus: bus) ?? 0) },
            set: { newValue in
                Task { await controller.setSendLevel(.channel, channel, toBus: bus, decibels: Float(newValue)) }
            }
        )
    }
}

#Preview {
    NavigationStack { OutputRoutingView(controller: .preview()) }
}
