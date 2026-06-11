//
//  AppRootView.swift
//  FluxKlang
//
//  Platform-adaptive root. iPhone (compact) uses a navigation stack; iPad and
//  Mac use a NavigationSplitView with a source-list sidebar. The real feature
//  surfaces (faders, routing, chain builder, presets) arrive in later phases.
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
    case faders = "Faders"
    case routing = "Routing"
    case chain = "Chain"
    case spatial = "Spatial"
    case presets = "Presets"
    case connection = "Connection"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .faders: return "slider.vertical.3"
        case .routing: return "point.topleft.down.to.point.bottomright.curvepath"
        case .chain: return "point.3.connected.trianglepath.dotted"
        case .spatial: return "hifispeaker.2"
        case .presets: return "square.grid.2x2"
        case .connection: return "antenna.radiowaves.left.and.right"
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
    var body: some View {
        TabView {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    SectionDetail(section: section)
                }
                .tabItem { Label(section.rawValue, systemImage: section.systemImage) }
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
        case .faders:
            FadersView()
        case .connection:
            ConnectionView()
        case .routing:
            RoutingView()
        case .chain:
            ChainCanvasView()
        case .spatial:
            SpatialView()
        case .presets:
            PresetsView()
        }
    }
}

#Preview {
    AppRootView()
        .environment(AppModel.preview())
}
