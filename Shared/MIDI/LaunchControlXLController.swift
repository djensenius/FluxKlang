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
    /// The stream's profile and sender cleanup, used on init and on every restart.
    let sourcePolicy: LaunchControlXLSourcePolicy
    /// Every matched endpoint feeds this one logical source. Fresh on every restart, so a half message, running
    /// status or open SysEx never crosses one.
    @ObservationIgnored private var stream: LaunchControlXLStream
    /// Bumped by every restart; a delivery or sources report from an earlier start is dropped.
    @ObservationIgnored private var generation = 0
    /// The sorted source names last reported in the current start; empty after every restart.
    @ObservationIgnored private var sourceNames: [String] = []
    /// Mapped actions not yet dispatched, in feed order, each with the start and mode it was fed under. One drain at
    /// a time empties it; every restart clears it.
    @ObservationIgnored private var pendingActions: ArraySlice<PendingAction> = []
    @ObservationIgnored private var isDispatching = false

    init(
        fileStore: JSONFileStore = .shared,
        fileName: String = "launch-control-xl.json",
        defaultConfiguration: LaunchControlXLConfiguration? = .bundled(),
        makeMIDIInput: @escaping @MainActor () -> any LaunchControlXLInput
            = HardwareServiceFactories.current.makeLaunchControlXLInput,
        sourcePolicy: LaunchControlXLSourcePolicy = .default
    ) {
        self.fileStore = fileStore
        self.fileName = fileName
        self.makeMIDIInput = makeMIDIInput
        self.sourcePolicy = sourcePolicy
        stream = Self.freshStream(profile: sourcePolicy.profile)
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

    nonisolated private static func freshStream(profile: MIDISourceProfile) -> LaunchControlXLStream {
        do throws(MIDISourceRefusal) {
            return try LaunchControlXLStream.make(profile: profile)
        } catch {
            preconditionFailure("Invalid Launch Control XL source profile: \(error)")
        }
    }

    private func restart() {
        midiInput?.stop()
        stream = Self.freshStream(profile: sourcePolicy.profile)
        sourceNames = []  // Defensive: each input's stop() already reports [] through the current callback.
        pendingActions = []
        generation += 1
        let generation = generation
        guard configuration.mode != .disabled else {
            status = .disabled
            return
        }
        status = .waiting
        let midiInput = midiInput ?? makeMIDIInput()
        self.midiInput = midiInput
        midiInput.start(
            sourceNameContains: configuration.mapping.sourceNameContains,
            onPackets: { [weak self] batch in
                self?.deliver(batch, generation: generation)
            },
            onSourcesChanged: { [weak self] names in
                self?.sourcesChanged(names, generation: generation)
            }
        )
    }

    /// CoreMIDI may report on every notification, so under `.resetStream` the stream is reset only when the sorted
    /// names differ from the last ones seen in this start. A report from an earlier start changes nothing.
    private func sourcesChanged(_ names: [String], generation: Int) {
        guard generation == self.generation else { return }
        status = names.isEmpty ? .waiting : .connected(names)
        let sorted = names.sorted()
        guard sorted != sourceNames else { return }
        sourceNames = sorted
        if sourcePolicy.sourceChange == .resetStream {
            stream.reset()
        }
    }

    /// The input path: the batch is fed synchronously, in delivery order, unless it belongs to an earlier start.
    /// After a gap, framing is cleared before the batch is fed, so bytes on either side of the gap never join.
    private func deliver(_ batch: MIDIPacketBatch, generation: Int) {
        guard generation == self.generation else { return }
        if batch.afterGap { stream.reset() }
        enqueue(configuration.mapping.actions(for: stream.feed(packets: batch.packets)))
        Task { [weak self] in await self?.dispatchPendingActions() }
    }

    /// Applies every packet of the batch, in order, before the first dispatch, then dispatches its actions in order.
    /// Called while any drain is running, it only queues its actions behind the current ones and returns.
    func receive(packets: [[UInt8]]) async {
        enqueue(configuration.mapping.actions(for: stream.feed(packets: packets)))
        await dispatchPendingActions()
    }

    /// Each valid message goes through the stream as a complete control change; invalid ones are dropped.
    func receive(_ messages: [MIDIControlChange]) async {
        enqueue(configuration.mapping.actions(for: stream.feed(messages)))
        await dispatchPendingActions()
    }

    /// Eligibility is fixed here, at feed time: an action fed in Monitor is never dispatched, even if the mode
    /// changes to Control before the drain reaches it.
    private func enqueue(_ actions: [LaunchControlXLAction]) {
        let shouldDispatch = configuration.mode == .control
        pendingActions += actions.map {
            PendingAction(action: $0, generation: generation, shouldDispatch: shouldDispatch)
        }
    }

    /// Dispatches queued actions one at a time, in queue order, awaiting each handler. A second caller returns at
    /// once while a drain runs; the running drain dispatches what it queued. Every drained action becomes
    /// `lastAction`; only one fed in Control, in the current start, while still in Control, reaches the handler.
    /// Each action is taken from the front of the slice in O(1), so a long queue drains in linear time.
    func dispatchPendingActions() async {
        guard !isDispatching else { return }
        isDispatching = true
        defer { isDispatching = false }
        while let pending = pendingActions.popFirst() {
            lastAction = pending.action
            guard pending.shouldDispatch, pending.generation == generation, configuration.mode == .control,
                  let actionHandler else { continue }
            await actionHandler(pending.action)
        }
    }

    private func persist() async {
        await fileStore.save(configuration, to: fileName)
    }

    private struct PendingAction {
        let action: LaunchControlXLAction
        let generation: Int
        let shouldDispatch: Bool
    }
}
