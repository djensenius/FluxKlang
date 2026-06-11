//
//  AppModel.swift
//  FluxKlang
//
//  App-level coordinator that owns the active WingController. It swaps the
//  controller when moving between a live WING connection and offline Demo Mode,
//  so the rest of the app simply observes `wing`.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// The active controller. Replaced when switching between live and demo.
    private(set) var wing: WingController

    init() {
        wing = WingController()
    }

    var isConnected: Bool { wing.connection.isConnected }
    var isDemo: Bool { wing.isDemo }

    /// Enters offline Demo Mode with a simulated WING, replacing any live link.
    func enterDemoMode() async {
        await wing.disconnect()
        let demo = WingController.demo()
        wing = demo
        await demo.connectDemo()
    }

    /// Connects to a real WING at `host`, leaving Demo Mode if it was active.
    func connect(host: String, port: UInt16 = WingNetwork.defaultPort) async {
        await wing.disconnect()
        let live = WingController(port: port)
        wing = live
        await live.connect(host: host)
    }

    /// Disconnects and returns to a fresh, idle live controller.
    func disconnect() async {
        await wing.disconnect()
        wing = WingController()
    }
}

extension AppModel {
    /// An app model whose controller is a populated demo, for SwiftUI previews.
    static func preview() -> AppModel {
        let model = AppModel()
        model.wing = .preview()
        return model
    }
}
