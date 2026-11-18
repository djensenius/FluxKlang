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

enum MixDestination: String, CaseIterable, Identifiable {
    case faders = "Faders"
    case scenes = "Scenes"

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    /// The active controller. Replaced when switching between live and demo.
    private(set) var wing: WingController
    let wingLifecycle: HostWingLifecycle

    /// Persisted configurable fader bank.
    let faderLayout: FaderLayoutStore

    /// USB MIDI integration for the Novation Launch Control XL 3.
    let launchControlXL: LaunchControlXLController

    /// User-editable equipment library for the chain builder.
    let equipment: EquipmentStore

    /// Named, switchable routing setups. Each environment bundles outboard
    /// effects, how instruments feed them, and its own drag-and-drop canvas
    /// graph; switching pushes the whole rig.
    let environments: EnvironmentStore

    /// The single global Home map of equipment ports to WING local connectors.
    let studioConnections: StudioConnectionsStore

    /// Saved presets / scene snapshots.
    let presets: PresetStore

    /// Named routing snapshots — the patchbay's Flock PATCH-style capture of the
    /// whole input/output patch, recalled instantly and independently of levels.
    let routingSnapshots: RoutingSnapshotStore

    /// Speaker layout and spatially-placed instruments for surround mixing.
    let spatial: SpatialStore

    /// Created explicitly and retained while its unsaved document has no open window.
    private(set) var performanceProjectSession: PerformanceProjectSession?

    /// The one read-only package inspection owner shared by every root window. Performs no IO until asked.
    let packageInspections = ProjectPackageInspectionSession()

    /// Shared read-only assistant domain plus local pending Studio drafts.
    let assistant: AssistantCoordinator

    /// Local provider choice plus Keychain-backed GitHub Copilot credentials.
    let assistantProviderSettings: AssistantProviderSettings

    /// User-visible assistant conversations, generation, history and speech.
    let assistantChat: AssistantChatController

    /// In-memory reviewed live actions. Neither reviews nor permissions are persisted.
    @ObservationIgnored lazy var assistantActions = makeAssistantActionController()

    /// Network scanner for finding WING consoles.
    let discovery: WingDiscovery

    /// Selectable app-icon manager (re-applies the saved icon on launch).
    let appIcon: AppIconManager

    private let lastHostKey = "fluxklang.lastHost"
    /// Service seams; the live WING transport and Local Network evidence come from here.
    let hardware: HardwareServiceFactories

    /// Observes external iCloud key-value-store changes so stores reload when
    /// another device syncs updated state. Held so the observer is removed when
    /// this model is deallocated.
    private var cloudObserver: CloudChangeObserver?
    private var siriIndexingTask: Task<Void, Never>?

    /// The currently selected sidebar section (also driven by Mac menu commands).
    var section: AppSection = .studio

    /// The visible surface within the consolidated Mix destination.
    var mixDestination: MixDestination = .faders

    /// Whether the Mac detail inspector is shown.
    var isInspectorPresented = false

    /// Global toolbar presentation for the assistant without changing context.
    var isAssistantPresented = false

    /// The fader strip shown in the inspector, if any.
    var selectedFaderID: FaderStrip.ID?

    /// Bumped by the "New Preset" command so the Presets screen can prompt.
    private(set) var newPresetRequestID = 0

    /// The most recently connected WING host, persisted across launches and used
    /// as a fallback when broadcast discovery finds nothing.
    var lastHost: String? {
        get { AppPersistence.defaults.string(forKey: lastHostKey) }
        set { AppPersistence.defaults.setValue(newValue, forKey: lastHostKey) }
    }

    init(
        assistant: AssistantCoordinator = AssistantCoordinator(),
        assistantProviderSettings: AssistantProviderSettings = AssistantProviderSettings(),
        wing: WingController? = nil,
        wingLifecycle: HostWingLifecycle? = nil,
        hardware: HardwareServiceFactories = .current,
        launchControlXLStore: JSONFileStore = .shared,
        domainStore: JSONFileStore? = nil,
        assistantConversationStore: AssistantConversationStore? = nil,
        assistantSpokenRepliesDefaults: UserDefaults? = nil
    ) {
        faderLayout = FaderLayoutStore(store: domainStore)
        equipment = EquipmentStore(store: domainStore)
        environments = EnvironmentStore(store: domainStore)
        if let domainStore {
            studioConnections = StudioConnectionsStore(fileStore: domainStore)
        } else {
            studioConnections = StudioConnectionsStore()
        }
        presets = PresetStore(store: domainStore)
        routingSnapshots = RoutingSnapshotStore(store: domainStore)
        spatial = SpatialStore(store: domainStore)
        appIcon = AppIconManager()
        self.wing = wing ?? WingController(hardware: hardware)
        self.wingLifecycle = wingLifecycle ?? HostWingLifecycle()
        self.hardware = hardware
        discovery = WingDiscovery(hardware: hardware)
        launchControlXL = LaunchControlXLController(
            fileStore: launchControlXLStore, makeMIDIInput: hardware.makeLaunchControlXLInput)
        self.assistant = assistant
        self.assistantProviderSettings = assistantProviderSettings
        let fallback = AssistantFallbackGenerator(coordinator: assistant)
        let generator = ConfigurableAssistantGenerator(
            settings: assistantProviderSettings,
            coordinator: assistant,
            appleGenerator: FoundationModelAssistantGenerator(coordinator: assistant),
            fallback: fallback
        )
        if let assistantConversationStore {
            self.assistantChat = AssistantChatController(
                coordinator: assistant, store: assistantConversationStore, generator: generator,
                spokenRepliesDefaults: assistantSpokenRepliesDefaults ?? AppPersistence.defaults)
        } else {
            self.assistantChat = AssistantChatController(
                coordinator: assistant, generator: generator,
                spokenRepliesDefaults: assistantSpokenRepliesDefaults ?? AppPersistence.defaults)
        }
        configureAssistantMixer()
        configureAssistantActions()
    }

    var isConnected: Bool { wing.connection.isConnected }
    var isDemo: Bool { wing.isDemo }

    func newPerformanceProject(window: WindowID, widthClass: WorkspaceWidthClass) throws {
        performanceProjectSession = try PerformanceProjectSession.openOrCreate(
            existing: performanceProjectSession, window: window, widthClass: widthClass
        )
        section = .workspace
    }

    /// Loads all persisted stores. Call once when the app launches.
    func loadStores() async {
        await faderLayout.load()
        await loadLaunchControlXL()
        await equipment.load()
        await environments.load()
        environments.migrateEffectEquipmentLinks(using: equipment.items)
        await studioConnections.load(
            equipment: equipment.items,
            environments: environments.environments,
            activeID: environments.activeID
        )
        await presets.load()
        await routingSnapshots.load()
        await spatial.load()
        await assistant.load()
        await assistantChat.load()
        scheduleSiriEntityIndexing()
        startObservingCloudChanges()
        if allowsStartupReconnect(), let lastHost {
            await connect(host: lastHost)
        }
        await awaitDomainScheduledSaveSnapshots()
    }

    /// Begins watching iCloud for changes pushed from the user's other devices,
    /// reloading every store when they arrive.
    private func startObservingCloudChanges() {
        guard cloudObserver == nil else { return }
        cloudObserver = CloudChangeObserver { [weak self] in
            Task { @MainActor in await self?.reloadStores() }
        }
    }

    /// Re-reads every persisted store, used when iCloud syncs new state.
    func reloadStores() async {
        assistantActions.cancel()
        await faderLayout.reload()
        await equipment.reload()
        await environments.reload()
        environments.migrateEffectEquipmentLinks(using: equipment.items)
        await studioConnections.reload(
            equipment: equipment.items,
            environments: environments.environments,
            activeID: environments.activeID
        )
        await presets.reload()
        await routingSnapshots.reload()
        await spatial.reload()
        scheduleSiriEntityIndexing()
        await awaitDomainScheduledSaveSnapshots()
    }

    /// Awaits the Siri indexing task captured when this method starts.
    func awaitSiriEntityIndexingSnapshot() async {
        let task = siriIndexingTask
        await task?.value
    }

    private func scheduleSiriEntityIndexing() {
        let previousTask = siriIndexingTask
        previousTask?.cancel()
        siriIndexingTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await SiriEntityIntegration.indexCurrentEntities(model: self)
        }
    }

    /// Enters offline Demo Mode with a simulated WING, replacing any live link.
    @discardableResult
    func enterDemoMode() async -> HostWingLifecycle.Outcome {
        await replaceWing {
            let demo = WingController.demo()
            self.wing = demo
            let outcome = await HostWingLifecycle.startUnlessCancelled {
                await demo.connectDemo()
                return .success(.demo)
            }
            return self.candidate(demo, outcome: outcome)
        }
    }

    /// Connects to a real WING at `host`, leaving Demo Mode if it was active.
    @discardableResult
    func connect(host: String, port: UInt16 = WingNetwork.defaultPort) async -> HostWingLifecycle.Outcome {
        await replaceWing {
            let live = self.makeLiveController(host: host, port: port)
            self.wing = live
            let outcome = await HostWingLifecycle.startUnlessCancelled {
                await live.connect(host: host)
                guard live.connection.isConnected, let session = live.sessionID else {
                    let reason: String
                    if case .failed(let detail) = live.connection { reason = detail } else {
                        reason = "Couldn't connect to \(host)."
                    }
                    return .failure(.connection(reason))
                }
                return .success(.connected(session))
            }
            return self.candidate(live, outcome: outcome) {
                self.rememberConnectedHost(host)
                await self.verifyTemporaryMovesAfterReconnect()
            }
        }
    }

    /// Disconnects and returns to a fresh, idle live controller.
    @discardableResult
    func disconnect() async -> HostWingLifecycle.Outcome {
        await replaceWing {
            let idle = WingController(hardware: self.hardware)
            self.wing = idle
            return self.candidate(idle, outcome: .success(.disconnected))
        }
    }

    @discardableResult
    func showAcceptanceConnectionFailure() async -> HostWingLifecycle.Outcome {
        await replaceWing {
            let failed = WingController.acceptanceFailure(
                reason: "Acceptance test: WING unavailable", hardware: self.hardware)
            self.wing = failed
            return self.candidate(failed, outcome: .success(.acceptanceFailure))
        }
    }

    private func replaceWing(
        start: @escaping @MainActor () async -> HostWingLifecycle.Candidate
    ) async -> HostWingLifecycle.Outcome {
        await wingLifecycle.replace {
            let old = self.wing
            self.assistantActions.cancel()
            return HostWingLifecycle.Operation(stopOld: { await old.disconnect() }, start: start)
        }
    }

    private func candidate(
        _ controller: WingController, outcome: HostWingLifecycle.Outcome,
        finish: @escaping @MainActor () async -> Void = {}
    ) -> HostWingLifecycle.Candidate {
        HostWingLifecycle.Candidate(outcome: outcome, isCurrent: {
            guard self.wing === controller else { return false }
            if case .success(.connected(let session)) = outcome {
                return controller.connection.isConnected && controller.sessionID == session
            }
            return true
        }, stop: { await controller.disconnect() }, finish: finish)
    }

    // MARK: - Selection & navigation

    /// The fader strip currently selected for the inspector, if it still exists.
    var selectedStrip: FaderStrip? {
        guard let id = selectedFaderID else { return nil }
        return faderLayout.layout.strips.first { $0.id == id }
    }

    /// Selects a strip and reveals it in the inspector.
    func selectStrip(_ strip: FaderStrip) {
        section = .mix
        mixDestination = .faders
        selectedFaderID = strip.id
        isInspectorPresented = true
    }

    /// Switches to Mix scenes and asks it to prompt for a new preset.
    func requestNewPreset() {
        section = .mix
        mixDestination = .scenes
        newPresetRequestID += 1
    }

    /// Switches back to Studio, the simplified home for patching and placement.
    func requestSpatialPlacement() {
        section = .studio
    }

    /// Menu (⌘R) behaviour: disconnect when connected or connecting, otherwise reconnect to the
    /// last known WING if one is remembered.
    func toggleConnection() async {
        let disconnectRequested = offersDisconnect
        if disconnectRequested {
            await disconnect()
        } else if let host = lastHost {
            await connect(host: host)
        }
    }

    /// Whether ⌘R can do anything right now.
    var canToggleConnection: Bool {
        offersDisconnect || lastHost != nil
    }

    var offersDisconnect: Bool {
        isConnected || wing.connection == .connecting
    }
}
