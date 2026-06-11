//
//  FluxKlangApp.swift
//  FluxKlang
//
//  iOS / iPadOS entry point.
//

import SwiftUI

@main
struct FluxKlangApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appModel)
        }
    }
}
