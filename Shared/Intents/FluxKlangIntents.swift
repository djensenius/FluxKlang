//
//  FluxKlangIntents.swift
//  FluxKlang
//
//  App Intents exposing FluxKlang to Shortcuts and Siri: connect, enter demo
//  mode, set a channel volume and recall a preset. They drive the shared
//  AppModel, so they act on the same controller and stores as the UI.
//

import AppIntents
import Foundation

struct EnterDemoModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Enter Demo Mode"
    static let description = IntentDescription("Explore FluxKlang offline with a simulated WING.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppModel.shared.enterDemoMode()
        return .result(dialog: "Entered Demo Mode.")
    }
}

struct ConnectToWingIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to WING"
    static let description = IntentDescription("Connect to a WING console by host, or the last one used.")
    static let openAppWhenRun = true

    @Parameter(title: "Host")
    var host: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let target = host ?? model.lastHost else {
            return .result(dialog: "No WING host is known yet. Connect once from the app first.")
        }
        await model.connect(host: target)
        return .result(dialog: model.isConnected ? "Connected to \(target)." : "Couldn't connect to \(target).")
    }
}

struct SetChannelVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Channel Volume"
    static let description = IntentDescription("Set a WING channel fader to a level in decibels.")
    static let openAppWhenRun = true

    @Parameter(title: "Channel", inclusiveRange: (1, 40))
    var channel: Int

    @Parameter(title: "Decibels", inclusiveRange: (-90.0, 10.0))
    var decibels: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard model.isConnected else {
            return .result(dialog: "Connect to a WING (or enter Demo Mode) first.")
        }
        await model.wing.setFader(.channel, channel, decibels: Float(decibels))
        return .result(dialog: "Set channel \(channel) to \(decibels.formatted()) dB.")
    }
}

struct RecallPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Recall Preset"
    static let description = IntentDescription("Recall a saved FluxKlang preset.")
    static let openAppWhenRun = true

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.presets.load()
        guard model.isConnected else {
            return .result(dialog: "Connect to a WING (or enter Demo Mode) first.")
        }
        guard let match = model.presets.presets.first(where: { $0.id == preset.id }) else {
            return .result(dialog: "That preset no longer exists.")
        }
        await model.recall(match)
        return .result(dialog: "Recalled \(match.name).")
    }
}

/// A preset exposed to Shortcuts so the user can pick one as an intent parameter.
struct PresetEntity: AppEntity {
    let id: UUID
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = PresetEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PresetEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        await AppModel.shared.presets.load()
        return AppModel.shared.presets.presets
            .filter { identifiers.contains($0.id) }
            .map { PresetEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        await AppModel.shared.presets.load()
        return AppModel.shared.presets.presets.map { PresetEntity(id: $0.id, name: $0.name) }
    }
}

struct FluxKlangShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EnterDemoModeIntent(),
            phrases: ["Enter \(.applicationName) Demo Mode"],
            shortTitle: "Enter Demo Mode",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ConnectToWingIntent(),
            phrases: ["Connect \(.applicationName)"],
            shortTitle: "Connect to WING",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: RecallPresetIntent(),
            phrases: ["Recall a \(.applicationName) preset"],
            shortTitle: "Recall Preset",
            systemImageName: "square.grid.2x2"
        )
    }
}
