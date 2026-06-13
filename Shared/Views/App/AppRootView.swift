//
//  AppRootView.swift
//  FluxKlang
//
//  Platform-adaptive root. iPhone (compact) uses a navigation stack; iPad and
//  Mac use a NavigationSplitView with a source-list sidebar. The real feature
//  surface first, with low-level WING tools grouped under Advanced.
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
    case faders = "Faders"
    case presets = "Presets"
    case connection = "Connection"
    case advanced = "Advanced"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .studio: return "square.stack.3d.up"
        case .faders: return "slider.vertical.3"
        case .presets: return "square.grid.2x2"
        case .connection: return "antenna.radiowaves.left.and.right"
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

    var body: some View {
        @Bindable var appModel = appModel
        TabView(selection: $appModel.section) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    SectionDetail(section: section)
                }
                .tabItem { Label(section.rawValue, systemImage: section.systemImage) }
                .tag(section)
            }
        }
    }
}
#endif

private struct SplitRoot: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        let selection = Binding<AppSection?>(
            get: { appModel.section },
            set: { appModel.section = $0 ?? .faders }
        )
        NavigationSplitView {
            List(AppSection.allCases, selection: selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("FluxKlang")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            #endif
        } detail: {
            detail
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
        case .faders:
            FadersView()
        case .connection:
            ConnectionView()
        case .presets:
            PresetsView()
        case .advanced:
            AdvancedView()
        }
    }
}

#Preview {
    AppRootView()
        .environment(AppModel.preview())
}
