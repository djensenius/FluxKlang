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
    case presets = "Presets"
    case connection = "Connection"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .faders: return "slider.vertical.3"
        case .routing: return "point.topleft.down.to.point.bottomright.curvepath"
        case .chain: return "point.3.connected.trianglepath.dotted"
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
    @State private var selection: AppSection? = .faders

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("FluxKlang")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            #endif
        } detail: {
            SectionDetail(section: selection ?? .faders)
        }
    }
}

private struct SectionDetail: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .faders:
            FadersView()
        case .connection:
            ConnectionView()
        case .routing, .chain, .presets:
            ComingSoon(section: section)
        }
    }
}

private struct ComingSoon: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView {
            Label(section.rawValue, systemImage: section.systemImage)
        } description: {
            Text("Coming soon — FluxKlang controls your Behringer WING Rack here.")
        }
        .navigationTitle(section.rawValue)
    }
}

#Preview {
    AppRootView()
        .environment(AppModel.preview())
}
