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
                Label(appModel.wing.connection.statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(statusTint)
                    .accessibilityIdentifier("connection.status.detail")
                    .accessibilityValue(appModel.wing.connection.statusLabel)
                if appModel.isDemo {
                    Text("Demo Mode — values are simulated and drift to feel live.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let reason = connectionFailureReason {
                Section("Connection Problem") {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    if let lastHost = appModel.lastHost {
                        Button {
                            connect(to: lastHost)
                        } label: {
                            Label("Retry \(lastHost)", systemImage: "arrow.clockwise")
                        }
                        .disabled(isWorking)
                        .accessibilityIdentifier("connection.retry")
                    }
                    Text("""
                    Check that this device and the WING are on the same network. \
                    Scan again or verify the IP address.
                    """)
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
                .accessibilityIdentifier("connection.demo")
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
                    .onSubmit { connect(to: host) }
                    .accessibilityIdentifier("connection.host")
                Button("Connect") { connect(to: host) }
                    .disabled(host.isEmpty || isWorking)
                    .accessibilityIdentifier("connection.connect")
            }

            DiscoveryView { selected in
                host = selected
                connect(to: selected)
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
                    .accessibilityIdentifier("connection.disconnect")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
        .onAppear {
            if host.isEmpty {
                host = appModel.lastHost ?? ""
            }
        }
    }

    private var statusSymbol: String {
        switch appModel.wing.connection {
        case .connected: return appModel.isDemo ? "play.circle.fill" : "antenna.radiowaves.left.and.right"
        case .connecting: return "ellipsis.circle"
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var statusTint: Color {
        appModel.wing.connection.statusTint(isDemo: appModel.isDemo)
    }

    private var connectionFailureReason: String? {
        guard case .failed(let reason) = appModel.wing.connection else { return nil }
        return reason
    }

    private func connect(to target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        host = trimmed
        guard !trimmed.isEmpty else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            await appModel.connect(host: trimmed)
        }
    }
}

#Preview {
    NavigationStack { ConnectionView() }
        .environment(AppModel.preview())
}
