//
//  CoPilotHandoff.swift
//  FluxKlang
//
//  One-tap hand-off to Behringer's WING Co-Pilot app for the deep editing that
//  FluxKlang intentionally defers (full channel EQ / dynamics / FX). FluxKlang
//  covers the everyday 99%; Co-Pilot is one button (or ⌘⇧P) away.
//
//  The Co-Pilot identifiers are configurable via Info.plist so they can be
//  corrected without a code change. The defaults are best-effort and should be
//  verified against the shipping Co-Pilot app:
//    • CoPilotURLScheme   – custom scheme to foreground the app (if any)
//    • CoPilotBundleID     – macOS bundle identifier, for NSWorkspace launch
//    • CoPilotAppStoreURL  – fallback when the app is not installed
//

import SwiftUI

/// Resolves Co-Pilot launch settings from Info.plist, falling back to defaults.
enum CoPilotConfig {
    static var urlScheme: String { string("CoPilotURLScheme") ?? "wing-copilot://" }
    static var bundleID: String { string("CoPilotBundleID") ?? "com.musictribe.WingCoPilot" }
    static var appStoreURLString: String {
        string("CoPilotAppStoreURL") ?? "itms-apps://itunes.apple.com/search?term=WING+Co-Pilot"
    }

    static var schemeURL: URL? { URL(string: urlScheme) }
    static var appStoreURL: URL? { URL(string: appStoreURLString) }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}

/// Launches / foregrounds WING Co-Pilot, gracefully falling back to the App Store
/// when it is not installed.
@MainActor
enum CoPilotHandoff {
    static func open(using openURL: OpenURLAction) {
        #if os(macOS)
        openWithWorkspace()
        #else
        if let scheme = CoPilotConfig.schemeURL {
            openURL(scheme) { accepted in
                if !accepted, let store = CoPilotConfig.appStoreURL { openURL(store) }
            }
        } else if let store = CoPilotConfig.appStoreURL {
            openURL(store)
        }
        #endif
    }

    #if os(macOS)
    /// macOS launch path: prefer the installed app (by bundle id, then scheme),
    /// otherwise open the App Store. Usable from `Commands`, which lack access to
    /// the SwiftUI environment's `openURL`.
    static func openWithWorkspace() {
        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: CoPilotConfig.bundleID) {
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else if let scheme = CoPilotConfig.schemeURL, workspace.urlForApplication(toOpen: scheme) != nil {
            workspace.open(scheme)
        } else if let store = CoPilotConfig.appStoreURL {
            workspace.open(store)
        }
    }
    #endif
}

/// A toolbar / menu button that hands off to WING Co-Pilot.
struct CoPilotButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            CoPilotHandoff.open(using: openURL)
        } label: {
            Label("Open in WING Co-Pilot", systemImage: "arrow.up.forward.app")
        }
        .help("Open WING Co-Pilot for deep channel editing (EQ, dynamics, FX)")
    }
}
