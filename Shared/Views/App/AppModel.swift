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

    /// Persisted configurable fader bank.
    let faderLayout = FaderLayoutStore()

    /// User-editable equipment library for the chain builder.
    let equipment = EquipmentStore()

    /// The drag-and-drop signal-chain graph.
    let chain = ChainStore()

    /// Saved presets / scene snapshots.
    let presets = PresetStore()

    /// Speaker layout and spatially-placed instruments for surround mixing.
    let spatial = SpatialStore()

    /// Network scanner for finding WING consoles.
    let discovery = WingDiscovery()

    private let lastHostKey = "fluxklang.lastHost"

    /// The currently selected sidebar section (also driven by Mac menu commands).
    var section: AppSection = .faders

    /// Whether the Mac detail inspector is shown.
    var isInspectorPresented = false

    /// The fader strip shown in the inspector, if any.
    var selectedFaderID: FaderStrip.ID?

    /// Bumped by the "New Preset" command so the Presets screen can prompt.
    private(set) var newPresetRequestID = 0

    /// The most recently connected WING host, persisted across launches and used
    /// as a fallback when broadcast discovery finds nothing.
    var lastHost: String? {
        get { UserDefaults.standard.string(forKey: lastHostKey) }
        set { UserDefaults.standard.setValue(newValue, forKey: lastHostKey) }
    }

    init() {
        wing = WingController()
    }

    var isConnected: Bool { wing.connection.isConnected }
    var isDemo: Bool { wing.isDemo }

    /// Loads all persisted stores. Call once when the app launches.
    func loadStores() async {
        await faderLayout.load()
        await equipment.load()
        await chain.load()
        await presets.load()
        await spatial.load()
    }

    /// Applies the chain graph's implied routing to the WING.
    func applyChainRouting() async {
        await wing.apply(chain.wingSettings())
    }

    /// Recalls a preset by applying its settings to the WING.
    func recall(_ preset: Preset) async {
        await wing.apply(preset.settings)
    }

    /// Captures the current mixer + routing state into a named preset.
    func savePreset(named name: String) {
        let settings = wing.snapshot(of: snapshotAddresses())
        presets.add(Preset(name: name, settings: settings))
    }

    /// Addresses captured into a preset snapshot: every fader-strip level and
    /// mute, plus channel input patches, main assignments and bus sends.
    private func snapshotAddresses() -> [String] {
        var addresses: [String] = []
        for strip in faderLayout.layout.strips {
            addresses.append(WingAddress.fader(strip.node.kind, strip.node.index))
            addresses.append(WingAddress.mute(strip.node.kind, strip.node.index))
        }
        for channel in 1...WingNodeKind.channel.count {
            addresses.append(WingAddress.channelSourceGroup(channel))
            addresses.append(WingAddress.channelSourceIndex(channel))
            for main in 1...WingNodeKind.main.count {
                addresses.append(WingAddress.mainOn(.channel, channel, toMain: main))
            }
            for bus in 1...WingNodeKind.bus.count {
                addresses.append(WingAddress.sendOn(.channel, channel, toBus: bus))
                addresses.append(WingAddress.sendLevel(.channel, channel, toBus: bus))
            }
        }
        return addresses
    }

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
        if live.connection.isConnected {
            lastHost = host
        }
    }

    /// Disconnects and returns to a fresh, idle live controller.
    func disconnect() async {
        await wing.disconnect()
        wing = WingController()
    }

    // MARK: - Spatial

    /// Computes DBAP gains for a source and pushes the resulting bus sends to the
    /// WING. Stereo sources drive their two channels independently.
    func applyPlacement(_ source: SpatialSource) async {
        let speakers = spatial.array.speakers
        guard !speakers.isEmpty else { return }
        let positions = speakers.map(\.position)
        for placement in source.channelPlacements() {
            let gains = SpatialPanner.gains(source: placement.point, speakers: positions)
            for (index, speaker) in speakers.enumerated() where speaker.node.kind == .bus {
                let bus = speaker.node.index
                let channel = placement.channel.index
                let decibels = SpatialPanner.decibels(forGain: gains[index])
                await wing.setSend(.channel, channel, toBus: bus, on: true)
                await wing.setSendLevel(.channel, channel, toBus: bus, decibels: decibels)
            }
        }
    }

    /// Re-applies every placed source. Used by the "Apply" action.
    func applyAllPlacements() async {
        for source in spatial.sources {
            await applyPlacement(source)
        }
    }

    /// Sets a stereo speaker pair's level (normalised), with an optional balance
    /// offset (`-1...1`) trimming left versus right.
    func setSpeakerPair(_ pair: SpeakerPair, position: Float, balance: Float = 0) async {
        let leftPosition = min(max(position - balance / 2, 0), 1)
        let rightPosition = min(max(position + balance / 2, 0), 1)
        if let left = spatial.array.speaker(pair.left) {
            await wing.setFader(left.node.kind, left.node.index, position: leftPosition)
        }
        if let right = spatial.array.speaker(pair.right) {
            await wing.setFader(right.node.kind, right.node.index, position: rightPosition)
        }
    }

    /// Mutes or unmutes both speakers in a pair.
    func setSpeakerPairMuted(_ pair: SpeakerPair, muted: Bool) async {
        if let left = spatial.array.speaker(pair.left) {
            await wing.setMute(left.node.kind, left.node.index, muted: muted)
        }
        if let right = spatial.array.speaker(pair.right) {
            await wing.setMute(right.node.kind, right.node.index, muted: muted)
        }
    }

    // MARK: - Selection & navigation

    /// The fader strip currently selected for the inspector, if it still exists.
    var selectedStrip: FaderStrip? {
        guard let id = selectedFaderID else { return nil }
        return faderLayout.layout.strips.first { $0.id == id }
    }

    /// Selects a strip and reveals it in the inspector.
    func selectStrip(_ strip: FaderStrip) {
        section = .faders
        selectedFaderID = strip.id
        isInspectorPresented = true
    }

    /// Switches to the Presets section and asks it to prompt for a new preset.
    func requestNewPreset() {
        section = .presets
        newPresetRequestID += 1
    }

    /// Menu (⌘R) behaviour: disconnect when connected, otherwise reconnect to the
    /// last known WING if one is remembered.
    func toggleConnection() async {
        if isConnected {
            await disconnect()
        } else if let host = lastHost {
            await connect(host: host)
        }
    }

    /// Whether ⌘R can do anything right now.
    var canToggleConnection: Bool {
        isConnected || lastHost != nil
    }
}

extension AppModel {
    /// The process-wide model used by the app scenes and by App Intents, so a
    /// Shortcut/Siri action drives the same controller and stores as the UI.
    static let shared = AppModel()

    /// An app model whose controller is a populated demo, for SwiftUI previews.
    static func preview() -> AppModel {
        let model = AppModel()
        model.wing = .preview()
        return model
    }
}
