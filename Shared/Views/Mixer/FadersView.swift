//
//  FadersView.swift
//  FluxKlang
//
//  A scrollable bank of mixer strips. Shows the WING channels (named after the
//  user's gear in Demo Mode) plus the main. When nothing is connected it offers
//  a one-tap route into Demo Mode.
//

import SwiftUI

struct FadersView: View {
    @Environment(AppModel.self) private var appModel

    private var controller: WingController { appModel.wing }

    private var slots: [FaderSlot] {
        (1...16).map { FaderSlot(kind: .channel, index: $0) } + [FaderSlot(kind: .main, index: 1)]
    }

    var body: some View {
        Group {
            if controller.connection.isConnected {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(slots) { slot in
                            FaderStripView(controller: controller, kind: slot.kind, index: slot.index)
                        }
                    }
                    .padding()
                }
            } else {
                unavailable
            }
        }
        .navigationTitle("Faders")
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "slider.vertical.3")
        } description: {
            Text("Connect to your WING, or try Demo Mode to explore offline.")
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

private struct FaderSlot: Identifiable {
    let kind: WingNodeKind
    let index: Int
    var id: String { "\(kind.rawValue)-\(index)" }
}

#Preview {
    NavigationStack { FadersView() }
        .environment(AppModel.preview())
}
