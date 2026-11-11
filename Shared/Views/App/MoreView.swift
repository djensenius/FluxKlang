import SwiftUI

#if !os(macOS)
struct MoreView: View {
    @Environment(\.openURL) private var openURL
    let window: WindowID
    let newProject: () -> Void

    var body: some View {
        List {
            Section("Create") {
                NavigationLink(value: AppSection.workspace) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Workspace")
                            Text("Unsaved software-routing draft; not active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: AppSection.workspace.systemImage)
                    }
                }
                .accessibilityIdentifier("more.workspace")
            }

            Section("Console") {
                destination(
                    "Routing",
                    "Patch inputs, outputs and routing snapshots",
                    AppSection.patchbay.systemImage,
                    identifier: "more.routing"
                ) {
                    PatchbayView()
                }
                destination(
                    "Connection",
                    "Find a WING, reconnect or enter Demo Mode",
                    AppSection.connection.systemImage,
                    identifier: "more.connection"
                ) {
                    ConnectionView()
                }
            }

            Section("Help & Settings") {
                destination(
                    "Learn FluxKlang",
                    "Understand signal flow, scenes and patching",
                    AppSection.tutorial.systemImage,
                    identifier: "more.learn"
                ) {
                    TutorialView()
                }
                destination(
                    "Settings",
                    "Mixer layout, connection details and appearance",
                    "gearshape",
                    identifier: "more.settings"
                ) {
                    SettingsContentView()
                }
                Button {
                    CoPilotHandoff.open(using: openURL)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open WING Co-Pilot")
                            Text("Continue into full EQ, dynamics and effects")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                }
            }

            Section("Compatibility") {
                destination(
                    "Advanced Tools",
                    "Raw routing and legacy editors",
                    AppSection.advanced.systemImage,
                    identifier: "more.advanced"
                ) {
                    AdvancedView()
                }
            }
        }
        .navigationTitle("More")
        .navigationDestination(for: AppSection.self) { section in
            SectionDetail(section: section, window: window, newProject: newProject)
        }
    }

    private func destination<Destination: View>(
        _ title: String,
        _ detail: String,
        _ systemImage: String,
        identifier: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif
