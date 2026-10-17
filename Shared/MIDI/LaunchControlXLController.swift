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
    private let midiInput = CoreMIDIInput()
    private var actionHandler: ((LaunchControlXLAction) async -> Void)?

    init(
        fileStore: JSONFileStore = .shared,
        fileName: String = "launch-control-xl.json",
        defaultConfiguration: LaunchControlXLConfiguration? = .bundled()
    ) {
        self.fileStore = fileStore
        self.fileName = fileName
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

    private func restart() {
        midiInput.stop()
        guard configuration.mode != .disabled else {
            status = .disabled
            return
        }
        status = .waiting
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

    func receive(_ messages: [MIDIControlChange]) async {
        for message in messages {
            guard let action = configuration.mapping.action(for: message) else { continue }
            lastAction = action
            guard configuration.mode == .control, let actionHandler else { continue }
            await actionHandler(action)
        }
    }

    private func persist() async {
        await fileStore.save(configuration, to: fileName)
    }
}
