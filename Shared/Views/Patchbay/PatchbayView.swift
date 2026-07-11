//
//  PatchbayView.swift
//  FluxKlang
//
//  A Flock PATCH-style patchbay for the WING. Two crosspoint grids — physical
//  input sources → channel inputs, and internal sources (main/bus/matrix) →
//  physical output sockets — plus named "routing snapshots" that capture the
//  whole patch and recall it instantly. Everything syncs live with the console
//  (and the demo simulator).
//

import SwiftUI

struct PatchbayView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case inputs = "Inputs"
        case outputs = "Outputs"
        case snapshots = "Snapshots"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var appModel
    @State private var tab: Tab = .inputs

    var body: some View {
        Group {
            if appModel.wing.connection.isConnected {
                content
            } else {
                notConnected
            }
        }
        .navigationTitle("Patchbay")
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch tab {
            case .inputs:
                InputPatchbayGrid(controller: appModel.wing)
            case .outputs:
                OutputPatchbayGrid(controller: appModel.wing)
            case .snapshots:
                RoutingSnapshotsView()
            }
        }
    }

    private var notConnected: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        } description: {
            Text("Connect to your WING, or try Demo Mode to explore the patchbay offline.")
        } actions: {
            Button {
                Task { await appModel.enterDemoMode() }
            } label: {
                Label("Enter Demo Mode", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Shared sizing and cell styling for the patchbay crosspoint grids.
enum PatchbayGrid {
    static let cell: CGFloat = 30
    static let rowHeader: CGFloat = 132
    static let spacing: CGFloat = 3

    /// A lit / unlit crosspoint button.
    static func crosspoint(isOn: Bool, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isOn ? tint : Color.secondary.opacity(0.12))
                .frame(width: cell, height: cell)
                .overlay {
                    if isOn {
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// A column-index header label.
    static func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: cell, height: cell)
    }
}

#Preview {
    NavigationStack { PatchbayView() }
        .environment(AppModel.preview())
}
