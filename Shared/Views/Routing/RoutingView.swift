//
//  RoutingView.swift
//  FluxKlang
//
//  Container for the routing tools: input patching, output routing and a compact
//  send matrix. All three sync live with the WING (and the demo simulator).
//

import SwiftUI

struct RoutingView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case input = "Inputs"
        case output = "Outputs"
        case matrix = "Matrix"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var appModel
    @State private var tab: Tab = .input

    var body: some View {
        Group {
            if appModel.wing.connection.isConnected {
                content
            } else {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("Connect to your WING, or try Demo Mode to explore routing offline.")
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
        .navigationTitle("Routing")
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch tab {
            case .input:
                InputPatchView(controller: appModel.wing)
            case .output:
                OutputRoutingView(controller: appModel.wing)
            case .matrix:
                PatchMatrixView(controller: appModel.wing)
            }
        }
    }
}

#Preview {
    NavigationStack { RoutingView() }
        .environment(AppModel.preview())
}
