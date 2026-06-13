//
//  AdvancedView.swift
//  FluxKlang
//
//  Low-level WING tools kept out of the primary Studio workflow.
//

import SwiftUI

struct AdvancedView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        RoutingView()
                    } label: {
                        advancedRow(
                            "Raw Routing",
                            "Inputs, outputs and bus send matrix",
                            "point.topleft.down.to.point.bottomright.curvepath"
                        )
                    }
                    NavigationLink {
                        ChainCanvasView()
                    } label: {
                        advancedRow(
                            "Legacy Patchbay",
                            "Old WING endpoint canvas",
                            "point.3.connected.trianglepath.dotted"
                        )
                    }
                    NavigationLink {
                        EnvironmentsView()
                    } label: {
                        advancedRow("Legacy Environments", "Previous effect-send builder", "rectangle.3.group")
                    }
                    NavigationLink {
                        SpatialView()
                    } label: {
                        advancedRow("Legacy Spatial", "Previous voice placement tools", "hifispeaker.2")
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Troubleshooting and compatibility tools. Start in Studio for the simplified workflow.")
                }
            }
            .navigationTitle("Advanced")
        }
    }

    private func advancedRow(_ title: String, _ subtitle: String, _ systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

#Preview {
    NavigationStack { AdvancedView() }
        .environment(AppModel.preview())
}
