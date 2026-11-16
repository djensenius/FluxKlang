//
//  LaunchControlXLController.swift
//  FluxKlang
//

import Foundation
import Observation

enum LaunchControlXLConnectionStatus: Equatable, Sendable {
    case disabled
    case waiting
    case connected([String])

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .waiting: "Waiting for Launch Control XL"
        case .connected(let names): names.joined(separator: ", ")
        }
    }
}

@MainActor
@Observable
final class LaunchControlXLController {
    private(set) var configuration: LaunchControlXLConfiguration
    private(set) var status: LaunchControlXLConnectionStatus = .disabled
    private(set) var bank = 0
    private(set) var lastAction: LaunchControlXLAction?

    private let fileStore: JSONFileStore
    private let fileName: String
    private let makeMIDIInput: @MainActor () -> any LaunchControlXLInput
    /// Created on the first non-disabled restart, so construction opens no MIDI client.
    @ObservationIgnored private var midiInput: (any LaunchControlXLInput)?
    private var actionHandler: ((LaunchControlXLAction) async -> Void)?
    /// The surface is one logical MIDI 1 source; its id only labels the outputs handed to the mapping.
    private static let stateInput = MIDIInputID(0)
    /// Fresh on every restart. Write-only today: no action reads it back, since every mapped CC is a plain
    /// `.controller` under `.unpaired`.
    @ObservationIgnored private var state = LaunchControlXLController.freshState()

    init(
        fileStore: JSONFileStore = .shared,
        fileName: String = "launch-control-xl.json",
        defaultConfiguration: LaunchControlXLConfiguration? = .bundled(),
        makeMIDIInput: @escaping @MainActor () -> any LaunchControlXLInput
            = HardwareServiceFactories.current.makeLaunchControlXLInput
    ) {
        self.fileStore = fileStore
        self.fileName = fileName
        self.makeMIDIInput = makeMIDIInput
        configuration = defaultConfiguration ?? LaunchControlXLConfiguration(
            version: 1,
            mode: .disabled,
            mapping: LaunchControlXLMapping(
                sourceNameContains: ["LCXL3", "Launch Control XL"],
                channel: 16,
                faderCCs: Array(5...12),
                panOrBalanceCCs: Array(13...20),
                selectCCs: Array(37...44),
                muteCCs: Array(45...52),
                bankPreviousCC: 103,
                bankNextCC: 102
            )
        )
    }

    func load() async {
        if let saved = await fileStore.load(LaunchControlXLConfiguration.self, from: fileName) {
            configuration = saved
        } else {
            await persist()
        }
        restart()
    }

    func setMode(_ mode: LaunchControlXLMode) async {
        configuration.mode = mode
        await persist()
        restart()
    }

    func setActionHandler(_ handler: @escaping (LaunchControlXLAction) async -> Void) {
        actionHandler = handler
    }

    func moveBank(_ delta: Int, stripCount: Int) {
        let lastBank = max((stripCount - 1) / 8, 0)
        bank = min(max(bank + delta, 0), lastBank)
    }

    func stripIndex(for slot: Int) -> Int {
        bank * 8 + slot
    }

    nonisolated private static func freshState() -> MIDI1PerformanceState {
        MIDI1PerformanceState(policy: LaunchControlXLMapping.sourceProfile.statePolicy)
    }

    private func restart() {
        midiInput?.stop()
        state = Self.freshState()
        guard configuration.mode != .disabled else {
            status = .disabled
            return
        }
        status = .waiting
        let midiInput = midiInput ?? makeMIDIInput()
        self.midiInput = midiInput
        midiInput.start(
            sourceNameContains: configuration.mapping.sourceNameContains,
            onMessages: { [weak self] messages in
                Task { @MainActor [weak self] in
                    await self?.receive(messages)
                }
            },
            onSourcesChanged: { [weak self] names in
                self?.status = names.isEmpty ? .waiting : .connected(names)
            }
        )
    }

    /// Applies the whole batch to the MIDI 1 state before the first dispatch, then dispatches its actions in order.
    func receive(_ messages: [MIDIControlChange]) async {
        let outputs = messages.compactMap(stateOutput(for:))
        for action in configuration.mapping.actions(for: outputs) {
            lastAction = action
            guard configuration.mode == .control, let actionHandler else { continue }
            await actionHandler(action)
        }
    }

    /// Nil for a channel outside 1...16, which no decoded message has; out-of-range data is a `.refused` output.
    private func stateOutput(for message: MIDIControlChange) -> MIDISourceOutput? {
        guard (1...MIDI1PerformanceState.channelCount).contains(message.channel) else { return nil }
        let event = MIDI1Event.channel(
            status: 0xB0 | UInt8(message.channel - 1), data1: message.controller, data2: message.value
        )
        do throws(MIDI1StateRefusal) {
            let update = try state.apply(event)
            return MIDISourceOutput(input: Self.stateInput, event: event, outcome: .applied(update))
        } catch {
            return MIDISourceOutput(input: Self.stateInput, event: event, outcome: .refused(error))
        }
    }

    private func persist() async {
        await fileStore.save(configuration, to: fileName)
    }
}
