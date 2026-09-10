//
//  AppRootView.swift
//  FluxKlang
//
//  Platform-adaptive root. Compact iPhone keeps the primary workflow to Studio,
//  Mix and More; iPad and Mac use a grouped source-list sidebar.
//

import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            #if os(macOS)
            SplitRoot()
            #else
            AdaptiveRoot()
            #endif
        }
        .task { await appModel.loadStores() }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case studio = "Studio"
    case mix = "Mix"
    case patchbay = "Routing"
    case connection = "Connection"
    case tutorial = "Learn"
    case advanced = "Compatibility"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .studio: return "square.stack.3d.up"
        case .mix: return "slider.vertical.3"
        case .patchbay: return "point.topleft.down.to.point.bottomright.curvepath"
        case .connection: return "antenna.radiowaves.left.and.right"
        case .tutorial: return "graduationcap"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

enum MixDestination: String, CaseIterable, Identifiable {
    case faders = "Faders"
    case scenes = "Scenes"

    var id: String { rawValue }
}

#if !os(macOS)
private struct AdaptiveRoot: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            TabRoot()
        } else {
            SplitRoot()
        }
    }
}

private struct TabRoot: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedTab = CompactTab.studio
    @State private var isShowingConnection = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SectionDetail(section: .studio)
            }
            .tabItem { Label("Studio", systemImage: AppSection.studio.systemImage) }
            .tag(CompactTab.studio)

            NavigationStack {
                MixView()
            }
            .tabItem { Label("Mix", systemImage: AppSection.mix.systemImage) }
            .tag(CompactTab.mix)

            NavigationStack {
                MoreView()
            }
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .tag(CompactTab.more)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ConnectionStatusButton { isShowingConnection = true }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
        }
        .sheet(isPresented: $isShowingConnection) {
            NavigationStack {
                ConnectionView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingConnection = false }
                        }
                    }
            }
        }
        .onAppear { selectedTab = compactTab(for: appModel.section) }
        .onChange(of: appModel.section) { _, section in
            selectedTab = compactTab(for: section)
        }
        .onChange(of: selectedTab) { _, tab in
            switch tab {
            case .studio:
                appModel.section = .studio
            case .mix:
                appModel.section = .mix
            case .more:
                break
            }
        }
    }

    private func compactTab(for section: AppSection) -> CompactTab {
        switch section {
        case .studio:
            return .studio
        case .mix:
            return .mix
        case .patchbay, .connection, .tutorial, .advanced:
            return .more
        }
    }
}

private enum CompactTab: Hashable {
    case studio
    case mix
    case more
}
#endif

private struct SplitRoot: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        let selection = Binding<AppSection?>(
            get: { appModel.section },
            set: { appModel.section = $0 ?? .studio }
        )
        NavigationSplitView {
            VStack(spacing: 0) {
                ConnectionStatusButton { appModel.section = .connection }
                    .padding()
                Divider()
                List(selection: selection) {
                    sidebarSection("Create", sections: [.studio, .mix])
                    sidebarSection("Console", sections: [.patchbay, .connection])
                    sidebarSection("Help", sections: [.tutorial])
                    sidebarSection("Advanced", sections: [.advanced])
                }
            }
            .navigationTitle("FluxKlang")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            #endif
        } detail: {
            detail
        }
    }

    private func sidebarSection(_ title: String, sections: [AppSection]) -> some View {
        Section(title) {
            ForEach(sections) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        @Bindable var appModel = appModel
        #if os(macOS)
        SectionDetail(section: appModel.section)
            .inspector(isPresented: $appModel.isInspectorPresented) {
                InspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        #else
        SectionDetail(section: appModel.section)
        #endif
    }
}

private struct SectionDetail: View {
    let section: AppSection

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    CoPilotButton()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .studio:
            StudioView()
        case .mix:
            MixView()
        case .patchbay:
            PatchbayView()
        case .connection:
            ConnectionView()
        case .tutorial:
            TutorialView()
        case .advanced:
            AdvancedView()
        }
    }
}

private struct MixView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: 0) {
            Picker("Mix View", selection: $appModel.mixDestination) {
                ForEach(MixDestination.allCases) { destination in
                    Text(destination.rawValue).tag(destination)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch appModel.mixDestination {
            case .faders:
                FadersView()
            case .scenes:
                PresetsView()
            }
        }
    }
}

#if !os(macOS)
private struct MoreView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section("Console") {
                destination(
                    "Routing",
                    "Patch inputs, outputs and routing snapshots",
                    AppSection.patchbay.systemImage
                ) {
                    PatchbayView()
                }
                destination(
                    "Connection",
                    "Find a WING, reconnect or enter Demo Mode",
                    AppSection.connection.systemImage
                ) {
                    ConnectionView()
                }
            }

            Section("Help & Settings") {
                destination(
                    "Learn FluxKlang",
                    "Understand signal flow, scenes and patching",
                    AppSection.tutorial.systemImage
                ) {
                    TutorialView()
                }
                destination("Settings", "Mixer layout, connection details and appearance", "gearshape") {
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
                    AppSection.advanced.systemImage
                ) {
                    AdvancedView()
                }
            }
        }
        .navigationTitle("More")
    }

    private func destination<Destination: View>(
        _ title: String,
        _ detail: String,
        _ systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
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
    }
}
#endif

private struct ConnectionStatusButton: View {
    @Environment(AppModel.self) private var appModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint("Opens connection controls")
    }

    private var title: String {
        switch appModel.wing.connection {
        case .connected:
            return appModel.isDemo ? "Demo WING" : "Live WING"
        case .connecting:
            return "Connecting"
        case .failed:
            return "Connection failed"
        case .disconnected:
            return "Not connected"
        }
    }

    private var detail: String {
        switch appModel.wing.connection {
        case .connected(let name):
            return name ?? appModel.wing.host ?? "Console state is live"
        case .connecting:
            return appModel.wing.host ?? "Opening the OSC connection"
        case .failed(let reason):
            return reason
        case .disconnected:
            return appModel.lastHost.map { "Last WING: \($0)" } ?? "Tap to connect or try Demo Mode"
        }
    }

    private var symbol: String {
        switch appModel.wing.connection {
        case .connected:
            return appModel.isDemo ? "play.circle.fill" : "antenna.radiowaves.left.and.right"
        case .connecting:
            return "ellipsis.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var tint: Color {
        switch appModel.wing.connection {
        case .connected:
            return appModel.isDemo ? .orange : .green
        case .connecting:
            return .blue
        case .failed:
            return .red
        case .disconnected:
            return .secondary
        }
    }
}

#Preview {
    AppRootView()
        .environment(AppModel.preview())
}
