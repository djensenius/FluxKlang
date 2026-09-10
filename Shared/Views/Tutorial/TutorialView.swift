//
//  TutorialView.swift
//  FluxKlang
//
//  A high-level concept guide. Not a click-through walkthrough — a short,
//  scannable primer on the ideas behind FluxKlang and the WING so newcomers
//  understand the model before diving into the tools.
//

import SwiftUI

struct TutorialView: View {
    var body: some View {
        List {
            ForEach(TutorialTopic.all) { topic in
                Section {
                    ForEach(topic.concepts) { concept in
                        conceptRow(concept)
                    }
                } header: {
                    Text(topic.title)
                }
            }
        }
        .navigationTitle("Tutorial")
    }

    private func conceptRow(_ concept: TutorialConcept) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(concept.title)
                    .font(.headline)
                Text(concept.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } icon: {
            Image(systemName: concept.systemImage)
                .font(.title3)
                .foregroundStyle(concept.tint)
                .frame(width: 28)
        }
    }
}

/// A single high-level concept shown in the tutorial.
struct TutorialConcept: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = .accentColor
}

/// A grouped set of related concepts.
struct TutorialTopic: Identifiable {
    let id = UUID()
    let title: String
    let concepts: [TutorialConcept]
}

extension TutorialTopic {
    static let all: [TutorialTopic] = [
        TutorialTopic(title: "The Big Picture", concepts: [
            TutorialConcept(
                title: "The console is the source of truth",
                detail: """
                FluxKlang controls a Behringer WING over the network. The WING is \
                multi-client, so changes from the WING app or the console itself \
                flow back into FluxKlang live — you're always looking at the real \
                state, never a stale copy.
                """,
                systemImage: "antenna.radiowaves.left.and.right",
                tint: .blue
            ),
            TutorialConcept(
                title: "Demo Mode",
                detail: """
                A full offline simulator sits behind the same interface as a live \
                console. Every feature works with no WING on the network — great \
                for exploring, screenshots or learning the app.
                """,
                systemImage: "play.circle",
                tint: .green
            ),
            TutorialConcept(
                title: "Metadata is not physical wiring",
                detail: """
                Live WING names and routing replies describe console state. FluxKlang's Studio Connections \
                describe the physical equipment cables you configured. A live scribble name can suggest a \
                friendly label, but it never proves or changes a cable.
                """,
                systemImage: "cable.connector",
                tint: .orange
            )
        ]),
        TutorialTopic(title: "Home, Moves & Review", concepts: [
            TutorialConcept(
                title: "Home vs Temporary Moves",
                detail: """
                Home is your normal saved cable map. A Temporary Move overlays different connectors without \
                editing Home. Move and Return Home flows require a cable checklist, routing preview, explicit \
                apply action and confirmed-reply verification.
                """,
                systemImage: "house",
                tint: .blue
            ),
            TutorialConcept(
                title: "Assistant and Siri create drafts",
                detail: """
                The assistant and Siri can create a pending Studio draft, never direct console changes. Review \
                validation and cable instructions before accepting. Accept adds semantic Studio routing only; \
                Listen is the separate action that can write compiled routing to a connected WING.
                """,
                systemImage: "checkmark.shield",
                tint: .green
            ),
            TutorialConcept(
                title: "On-device and private",
                detail: """
                Generation and push-to-talk transcription run on device when available, with a grounded fallback \
                when Foundation Models are unavailable. Audio is not retained. Visible conversation text may sync \
                through your private iCloud database.
                """,
                systemImage: "hand.raised.fill",
                tint: .purple
            )
        ]),
        TutorialTopic(title: "Signal Flow", concepts: [
            TutorialConcept(
                title: "Inputs → Channels → Buses → Outputs",
                detail: """
                Physical inputs are patched onto channels. Channels are sent to \
                buses (groups, effects, monitors) and assigned to the mains. Mains, \
                buses and matrices then feed the physical output sockets your \
                speakers and gear plug into.
                """,
                systemImage: "arrow.left.arrow.right",
                tint: .orange
            ),
            TutorialConcept(
                title: "Sources & groups",
                detail: """
                Every input and output source is a transport group (Local, AES50, \
                USB, StageConnect…) plus a 1-based index. Picking a source is just \
                choosing a group and a number.
                """,
                systemImage: "square.stack.3d.up",
                tint: .purple
            )
        ]),
        TutorialTopic(title: "The Patchbay", concepts: [
            TutorialConcept(
                title: "Crosspoint routing",
                detail: """
                The Patchbay is a Flock PATCH-style grid: sources along the top, \
                destinations down the side. Tap a crosspoint to route. Each channel \
                input and each output socket carries exactly one source, so lighting \
                a cell replaces whatever was there.
                """,
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                tint: .teal
            ),
            TutorialConcept(
                title: "Routing snapshots",
                detail: """
                Capture the entire patch — every input and output — as a named \
                snapshot, then recall the whole routing instantly. Snapshots touch \
                only routing, never your fader levels or mutes, so you can re-patch \
                without disturbing the mix.
                """,
                systemImage: "camera.on.rectangle",
                tint: .pink
            )
        ]),
        TutorialTopic(title: "Mixing & Recall", concepts: [
            TutorialConcept(
                title: "Faders",
                detail: """
                Build a bank of faders bound to any channels, buses or mains, with \
                live two-way sync and mute. The colored bar currently follows fader \
                position; it is simulated, not WING audio-level telemetry. On Mac, \
                scroll or arrow keys adjust, double-click resets to 0 dB and ⌥-drag \
                provides fine control.
                """,
                systemImage: "slider.vertical.3",
                tint: .indigo
            ),
            TutorialConcept(
                title: "Presets & scenes",
                detail: """
                Presets snapshot fader levels, mutes and routing together and \
                recall them with one tap (⌘1–9 on Mac). Use presets for whole-mix \
                scenes; use routing snapshots when you only want to change patching.
                """,
                systemImage: "square.grid.2x2",
                tint: .red
            ),
            TutorialConcept(
                title: "WING Co-Pilot hand-off",
                detail: """
                FluxKlang covers the everyday 99%. For the deep 1% — full EQ, \
                dynamics and FX — hand off to Behringer's WING Co-Pilot; both apps \
                share the same console as the source of truth.
                """,
                systemImage: "arrow.up.forward.app",
                tint: .gray
            )
        ])
    ]
}

#Preview {
    NavigationStack { TutorialView() }
}
