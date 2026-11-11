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
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var workspaceWindow = WindowID(uuid: UUID())
    @State private var workspaceFailure: String?
    #if DEBUG
    private let constructionObservation = AcceptanceLaunchConfiguration.isUITesting
        ? AppModel.captureUIConstructionObservation() : nil
    @State private var rootWorkObservation: UIStartupObservation.RootWork?
    #endif

    var body: some View {
        @Bindable var assistant = appModel.assistant
        Group {
            #if os(macOS)
            SplitRoot(window: workspaceWindow, newProject: newWorkspaceProject)
            #else
            AdaptiveRoot(window: workspaceWindow, widthClass: workspaceWidthClass, newProject: newWorkspaceProject)
            #endif
        }
        .onAppear { reconcileWorkspaceWindow() }
        .onChange(of: workspaceWidthClass) { _, _ in reconcileWorkspaceWindow() }
        .onChange(of: appModel.performanceProjectSession?.project.id) { _, _ in reconcileWorkspaceWindow() }
        // Navigation belongs to this outer root, not a destination or adaptive-width branch.
        .onDisappear {
            workspaceOperation { try appModel.closePerformanceProjectWindow(workspaceWindow) }
        }
        .alert("Workspace unavailable", isPresented: Binding(
            get: { workspaceFailure != nil },
            set: { if !$0 { workspaceFailure = nil } }
        )) {
            Button("OK", role: .cancel) { workspaceFailure = nil }
        } message: {
            Text(workspaceFailure ?? "")
        }
        .task {
            await appModel.loadStores()
            if AcceptanceLaunchConfiguration.isUITesting {
                await AcceptanceLaunchConfiguration.configure(appModel)
            }
            #if DEBUG
            let observeRootWork = constructionObservation != nil
                || ProcessInfo.processInfo.environment["FLUXKLANG_ISOLATED_TESTING"] == "1"
            if observeRootWork {
                rootWorkObservation = AppModel.captureUIRootWorkObservation()
            }
            #endif
        }
        #if DEBUG
        .modifier(StartupIsolationAccessibility(
            construction: constructionObservation,
            rootWork: rootWorkObservation
        ))
        #endif
        #if DEBUG && os(iOS)
        .modifier(UIAuditCaptureRootBridge())
        #endif
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
                appModel.isAssistantPresented = false
                appModel.section = .studio
            case .help:
                appModel.isAssistantPresented = false
            case nil:
                break
            }
        }
    }

    private var workspaceWidthClass: WorkspaceWidthClass {
        #if os(macOS)
        .regular
        #else
        horizontalSizeClass == .compact ? .compact : .regular
        #endif
    }

    private func newWorkspaceProject() {
        workspaceOperation {
            try appModel.newPerformanceProject(window: workspaceWindow, widthClass: workspaceWidthClass)
        }
    }

    private func reconcileWorkspaceWindow() {
        workspaceOperation {
            try appModel.reconcilePerformanceProjectWindow(workspaceWindow, widthClass: workspaceWidthClass)
        }
    }

    private func workspaceOperation(_ operation: () throws -> Void) {
        do {
            try operation()
            workspaceFailure = nil
        } catch {
            workspaceFailure = String(describing: error)
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

#if DEBUG
private struct StartupIsolationAccessibility: ViewModifier {
    let construction: UIStartupObservation.Construction?
    let rootWork: UIStartupObservation.RootWork?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let construction {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("startup.isolation.observation")
                .accessibilityValue(UIStartupObservation(
                    construction: construction,
                    rootAwaitedWork: rootWork
                ).encoded)
        } else {
            content
        }
    }
}
#endif

#if !os(macOS)
private struct AdaptiveRoot: View {
    let window: WindowID
    let widthClass: WorkspaceWidthClass
    let newProject: () -> Void

    var body: some View {
        if widthClass == .compact {
            CompactTabRoot(window: window, newProject: newProject)
        } else {
            SplitRoot(window: window, newProject: newProject)
        }
    }
}
#endif

private struct SplitRoot: View {
    @Environment(AppModel.self) private var appModel
    let window: WindowID
    let newProject: () -> Void

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
                    sidebarSection("Create", sections: [.studio, .workspace, .assistant, .mix])
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
        if appModel.section == .workspace {
            SectionDetail(section: .workspace, window: window, newProject: newProject)
        } else {
            SectionDetail(section: appModel.section, window: window, newProject: newProject)
            .inspector(isPresented: $appModel.isInspectorPresented) {
                InspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        }
        #else
        SectionDetail(section: appModel.section, window: window, newProject: newProject)
        #endif
    }
}

struct SectionDetail: View {
    @Environment(AppModel.self) private var appModel
    let section: AppSection
    let window: WindowID
    let newProject: () -> Void

    var body: some View {
        content
            .toolbar {
                if section != .assistant && section != .workspace {
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
        case .workspace:
            PerformanceWorkspaceView(
                session: appModel.performanceProjectSession, window: window, newProject: newProject
            )
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

struct MixView: View {
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

struct ConnectionStatusButton: View {
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
