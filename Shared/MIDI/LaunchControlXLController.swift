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
    /// Every matched endpoint feeds this one logical source. Fresh on every restart, so a half message, running
    /// status or open SysEx never crosses one.
    @ObservationIgnored private var stream = LaunchControlXLController.freshStream()

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

    nonisolated private static func freshStream() -> LaunchControlXLStream {
        do throws(MIDISourceRefusal) {
            return try LaunchControlXLStream.make()
        } catch {
            preconditionFailure("Invalid built-in Launch Control XL source profile: \(error)")
        }
    }

    private func restart() {
        midiInput?.stop()
        stream = Self.freshStream()
        guard configuration.mode != .disabled else {
            status = .disabled
            return
        }
        status = .waiting
        let midiInput = midiInput ?? makeMIDIInput()
        self.midiInput = midiInput
        midiInput.start(
            sourceNameContains: configuration.mapping.sourceNameContains,
            onPackets: { [weak self] packets in
                Task { @MainActor [weak self] in
                    await self?.receive(packets: packets)
                }
            },
            onSourcesChanged: { [weak self] names in
                self?.status = names.isEmpty ? .waiting : .connected(names)
            }
        )
    }

    /// Applies every packet of the batch, in order, before the first dispatch, then dispatches its actions in order.
    func receive(packets: [[UInt8]]) async {
        await dispatch(stream.feed(packets: packets))
    }

    /// Each valid message goes through the stream as a complete control change; invalid ones are dropped.
    func receive(_ messages: [MIDIControlChange]) async {
        await dispatch(stream.feed(messages))
    }

    private func dispatch(_ outputs: [MIDISourceOutput]) async {
        for action in configuration.mapping.actions(for: outputs) {
            lastAction = action
            guard configuration.mode == .control, let actionHandler else { continue }
            await actionHandler(action)
        }
    }

    private func persist() async {
        await fileStore.save(configuration, to: fileName)
    }
}
