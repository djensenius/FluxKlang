//
//  FluxKlangIntents.swift
//  FluxKlang
//
//  App Intents exposing FluxKlang to Shortcuts and Siri: connect, enter demo
//  mode, set a channel volume and recall a preset. They drive the shared
//  AppModel, so they act on the same controller and stores as the UI.
//

import AppIntents
import CoreSpotlight
import Foundation
import OSLog

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

struct DraftStudioPatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft Studio Patch"
    static let description = IntentDescription(
        "Create a reviewable Studio wiring draft without changing WING settings or routing."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Source Gear")
    var sourceGear: [EquipmentEntity]

    @Parameter(title: "Ordered Effects")
    var effects: [EffectEntity]?

    @Parameter(title: "Destination", default: .finalMix)
    var destination: DestinationEntity

    static var parameterSummary: some ParameterSummary {
        When(\.$effects, .hasAnyValue) {
            Summary("Draft \(\.$sourceGear) through \(\.$effects) to \(\.$destination)")
        } otherwise: {
            Summary("Draft \(\.$sourceGear) to \(\.$destination)")
        }
    }

    init() {}

    init(
        sourceGear: [EquipmentEntity],
        effects: [EffectEntity]? = nil,
        destination: DestinationEntity = .finalMix
    ) {
        self.sourceGear = sourceGear
        self.effects = effects
        self.destination = destination
    }

    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = await SiriDraftStudioAction.execute(
            sourceGear: sourceGear,
            effects: effects ?? [],
            destination: destination,
            model: AppModel.shared
        )
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

@MainActor
enum SiriDraftStudioAction {
    static func execute(
        sourceGear: [EquipmentEntity],
        effects: [EffectEntity],
        destination: DestinationEntity,
        model: AppModel
    ) async -> String {
        await model.equipment.load()
        await model.environments.load()
        model.environments.migrateEffectEquipmentLinks(using: model.equipment.items)
        await model.studioConnections.load(
            equipment: model.equipment.items,
            environments: model.environments.environments,
            activeID: model.environments.activeID
        )
        let context = model.assistantToolContext()
        let validSourceIDs = orderedIDs(
            sourceGear.map(\.id),
            available: Set(context.equipment.map(\.id))
        )
        let validEffectIDs = orderedIDs(
            effects.map(\.id),
            available: Set(context.effects.map(\.id))
        )
        let result = await model.assistant.perform(
            .buildStudioDraft(StudioWiringRequest(
                sourceInstrumentIDs: validSourceIDs,
                effectChainIDs: validEffectIDs,
                destination: destination.destination
            )),
            context: context
        )
        guard case .pendingDraft(let draft?) = result else {
            return "I couldn't create a Studio draft."
        }
        _ = await model.assistant.perform(.openReview, context: context)
        model.section = .studio
        return spokenSummary(for: draft)
    }

    static func spokenSummary(for draft: StudioPatchDraft) -> String {
        let path = draft.logicalRoutingSummary.first?.value ?? "Studio draft"
        if draft.hasErrors {
            let count = draft.validation.count
            return "Drafted \(path). Review \(count) issue\(count == 1 ? "" : "s") in FluxKlang."
        }
        return "Drafted \(path). Review it in FluxKlang."
    }

    private static func orderedIDs(_ identifiers: [UUID], available: Set<UUID>) -> [UUID] {
        var seen: Set<UUID> = []
        return identifiers.filter { available.contains($0) && seen.insert($0).inserted }
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
        AppShortcut(
            intent: DraftStudioPatchIntent(),
            phrases: [
                "Draft a patch in \(.applicationName)",
                "Help me wire gear with \(.applicationName)"
            ],
            shortTitle: "Draft Studio Patch",
            systemImageName: "point.topleft.down.to.point.bottomright.curvepath"
        )
    }
}

enum SiriEntityIntegration {
    private static let logger = Logger(
        subsystem: "org.davidjensenius.FluxKlang",
        category: "AppIntents"
    )

    @MainActor
    static func indexCurrentEntities(model: AppModel) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let equipment = model.equipment.items.map(EquipmentEntity.init)
        let effects = model.environments.activeEffects.map(EffectEntity.init)
        let environments = model.environments.environments.map(EnvironmentEntity.init)
        do {
            let index = fluxKlangSpotlightIndex()
            try await index.deleteAppEntities(ofType: EquipmentEntity.self)
            try await index.deleteAppEntities(ofType: EffectEntity.self)
            try await index.deleteAppEntities(ofType: EnvironmentEntity.self)
            try await index.deleteAppEntities(ofType: DestinationEntity.self)
            try await index.indexAppEntities(equipment)
            try await index.indexAppEntities(effects)
            try await index.indexAppEntities(environments)
            try await index.indexAppEntities(DestinationEntity.all)
        } catch is CancellationError {
            return
        } catch {
            logger.error("Unable to index App Entities: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    static func donateDraft(
        sourceIDs: [Equipment.ID],
        effectIDs: [Effect.ID],
        destination: StudioEndpointDestination,
        context: AssistantToolContext
    ) {
        let equipmentByID = Dictionary(
            context.equipment.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let effectsByID = Dictionary(
            context.effects.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let sourceEntities = sourceIDs.compactMap { equipmentByID[$0].map(EquipmentEntity.init) }
        let effectEntities = effectIDs.compactMap { effectsByID[$0].map(EffectEntity.init) }
        guard !sourceEntities.isEmpty else { return }
        let intent = DraftStudioPatchIntent(
            sourceGear: sourceEntities,
            effects: effectEntities.isEmpty ? nil : effectEntities,
            destination: DestinationEntity.all.first { $0.destination == destination } ?? .finalMix
        )
        intent.donate()
    }
}
