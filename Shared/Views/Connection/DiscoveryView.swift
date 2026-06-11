//
//  DiscoveryView.swift
//  FluxKlang
//
//  A Form section that scans the network for WING consoles and offers the
//  last-known host as a quick reconnect. Selecting an entry hands the host back
//  to the caller to connect.
//

import SwiftUI

struct DiscoveryView: View {
    @Environment(AppModel.self) private var appModel
    let onSelect: (String) -> Void

    var body: some View {
        Section("Discover") {
            Button(action: scan) {
                if appModel.discovery.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    }
                } else {
                    Label("Scan for WING", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .disabled(appModel.discovery.isScanning)

            ForEach(appModel.discovery.responders) { wing in
                Button { onSelect(wing.host) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wing.name)
                        Text(wing.model.map { "\($0) · \(wing.host)" } ?? wing.host)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if !appModel.discovery.isScanning && appModel.discovery.responders.isEmpty {
                Text("No consoles found yet. Make sure the WING is on this network, or enter its IP below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let last = appModel.lastHost {
                Button { onSelect(last) } label: {
                    Label("Reconnect to \(last)", systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }

    private func scan() {
        Task { await appModel.discovery.scan() }
    }
}

#Preview {
    Form {
        DiscoveryView { _ in }
    }
    .formStyle(.grouped)
    .environment(AppModel.preview())
}
