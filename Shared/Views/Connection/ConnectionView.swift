//
//  ConnectionView.swift
//  FluxKlang
//
//  Lets the user enter offline Demo Mode or connect to a real WING by IP, and
//  shows the current connection status.
//

import SwiftUI

struct ConnectionView: View {
    @Environment(AppModel.self) private var appModel
    @State private var host = ""
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Status") {
                Label(appModel.wing.connection.statusLabel, systemImage: statusSymbol)
                    .foregroundStyle(appModel.isConnected ? .primary : .secondary)
                if appModel.isDemo {
                    Text("Demo Mode — values are simulated and drift to feel live.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Demo Mode") {
                Button {
                    Task {
                        isWorking = true
                        await appModel.enterDemoMode()
                        isWorking = false
                    }
                } label: {
                    Label("Enter Demo Mode", systemImage: "play.circle.fill")
                }
                .disabled(isWorking)
                Text("Explore FluxKlang without a WING on the network — great for trying things offline.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connect to WING") {
                TextField("WING IP address", text: $host)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { connect() }
                Button("Connect") { connect() }
                    .disabled(host.isEmpty || isWorking)
            }

            if appModel.isConnected || appModel.wing.connection == .connecting {
                Section {
                    Button(role: .destructive) {
                        Task {
                            isWorking = true
                            await appModel.disconnect()
                            isWorking = false
                        }
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(isWorking)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
    }

    private var statusSymbol: String {
        switch appModel.wing.connection {
        case .connected: return appModel.isDemo ? "play.circle.fill" : "antenna.radiowaves.left.and.right"
        case .connecting: return "ellipsis.circle"
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func connect() {
        let target = host
        Task {
            isWorking = true
            await appModel.connect(host: target)
            isWorking = false
        }
    }
}

#Preview {
    NavigationStack { ConnectionView() }
        .environment(AppModel.preview())
}
