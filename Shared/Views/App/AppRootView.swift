//
//  AppRootView.swift
//  FluxKlang
//
//  Platform-adaptive root. Compact iPhone keeps the primary workflow to Studio,
//  Assistant, Mix and More; iPad and Mac use a grouped source-list sidebar.
//

import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var assistant = appModel.assistant
        Group {
            #if os(macOS)
            SplitRoot()
            #else
            AdaptiveRoot()
            #endif
        }
        .task {
            await appModel.loadStores()
            if AcceptanceLaunchConfiguration.isUITesting {
                await AcceptanceLaunchConfiguration.configure(appModel)
            }
        }
        .sheet(isPresented: helpPresented) {
            if case .help(let topic) = assistant.navigationTarget {
                AssistantHelpView(entry: FluxKlangHelpCatalog.entry(for: topic))
            }
        }
        .sheet(isPresented: assistantPresented) {
            NavigationStack {
                AssistantView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { appModel.isAssistantPresented = false }
                        }
                    }
            }
            .environment(appModel)
        }
        .onChange(of: assistant.navigationTarget) { _, target in
            switch target {
            case .reviewPendingDraft:
                appModel.section = .studio
            case .help:
                break
            case nil:
                break
            }
        }
    }

    private var helpPresented: Binding<Bool> {
        Binding(
            get: {
                if case .help = appModel.assistant.navigationTarget { return true }
                return false
            },
            set: { isPresented in
                if !isPresented {
                    appModel.assistant.clearNavigation()
                }
            }
        )
    }

    private var assistantPresented: Binding<Bool> {
        Binding(
            get: { appModel.isAssistantPresented },
            set: { appModel.isAssistantPresented = $0 }
        )
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case studio = "Studio"
    case assistant = "Assistant"
    case mix = "Mix"
    case patchbay = "Routing"
    case connection = "Connection"
    case tutorial = "Learn"
    case advanced = "Compatibility"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .studio: return "square.stack.3d.up"
        case .assistant: return "sparkles"
        case .mix: return "slider.vertical.3"
        case .patchbay: return "point.topleft.down.to.point.bottomright.curvepath"
        case .connection: return "antenna.radiowaves.left.and.right"
        case .tutorial: return "graduationcap"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
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
                SectionDetail(section: .assistant)
            }
            .tabItem { Label("Assistant", systemImage: AppSection.assistant.systemImage) }
            .tag(CompactTab.assistant)

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
            case .assistant:
                appModel.section = .assistant
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
        case .assistant:
            return .assistant
        case .mix:
            return .mix
        case .patchbay, .connection, .tutorial, .advanced:
            return .more
        }
    }
}

private enum CompactTab: Hashable {
    case studio
    case assistant
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
                    sidebarSection("Create", sections: [.studio, .assistant, .mix])
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
    @Environment(AppModel.self) private var appModel
    let section: AppSection

    var body: some View {
        content
            .toolbar {
                if section != .assistant {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            appModel.isAssistantPresented = true
                        } label: {
                            Label("Open Assistant", systemImage: "sparkles")
                        }
                        .accessibilityLabel("Open Assistant")
                        .accessibilityIdentifier("assistant.entry")
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .studio:
            StudioView()
        case .assistant:
            AssistantView()
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
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityHint("Opens connection controls")
        .accessibilityIdentifier("connection.status")
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
        appModel.wing.connection.statusTint(isDemo: appModel.isDemo)
    }
}

#Preview {
    AppRootView()
        .environment(AppModel.preview())
}
