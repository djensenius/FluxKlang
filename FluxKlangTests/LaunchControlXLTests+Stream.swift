//
//  LaunchControlXLTests+Stream.swift
//  FluxKlangTests
//

import Foundation
import Synchronization
import Testing
@testable import FluxKlang

/// The Launch Control XL on `MIDISourceRegistry` through `LaunchControlXLStream` (#80, slice MU3): pure stream tests
/// first, controller tests after. Synthetic bytes only; nothing starts CoreMIDI.
extension LaunchControlXLTests {
    static let runningStatusBytes: [UInt8] = [0xBF, 5, 127, 6, 0xF8, 64, 38, 127, 0xFE, 37, 127, 102, 127]
    static let runningStatusActions: [LaunchControlXLAction] = [
        .fader(slot: 0, value: 1), .fader(slot: 1, value: 64 / 127), .select(slot: 1), .select(slot: 0), .moveBank(1)
    ]

    static func bundledMapping() throws -> LaunchControlXLMapping {
        try #require(LaunchControlXLConfiguration.bundled()).mapping
    }

    /// Channel 16's stored value of `controller`.
    static func channel16(_ controller: Int, in stream: LaunchControlXLStream) throws -> UInt8 {
        let source = try #require(stream.snapshot.sources.first)
        let channel = try #require(source.state.channels.last)
        try #require(channel.controllers.indices.contains(controller))
        return channel.controllers[controller]
    }

    /// T1: running status split across two packets at every boundary, or one byte per packet, equals one feed.
    @Test func packetSplitAtEveryBoundaryMatchesOneFeed() throws {
        let mapping = try Self.bundledMapping()
        let bytes = Self.runningStatusBytes
        var whole = try LaunchControlXLStream.make()
        let expected = whole.feed(packets: [bytes])
        #expect(mapping.actions(for: expected) == Self.runningStatusActions)
        for split in 0...bytes.count {
            var stream = try LaunchControlXLStream.make()
            let outputs = stream.feed(packets: [Array(bytes.prefix(split)), Array(bytes.dropFirst(split))])
            #expect(outputs == expected, "split at \(split)")
            #expect(stream.snapshot == whole.snapshot, "split at \(split)")
        }
        var bytewise = try LaunchControlXLStream.make()
        #expect(bytewise.feed(packets: bytes.map { [$0] }) == expected)
        #expect(bytewise.snapshot == whole.snapshot)
    }

    /// T2: a SysEx spanning packets is one event; over the profile's bound it is dropped. SysEx cancels running
    /// status, so data bytes after F7 are ignored until the next status byte.
    @Test func sysExAcrossPacketsIsBoundedAndRecovers() throws {
        let mapping = try Self.bundledMapping()
        let packets: [[UInt8]] = [[0xBF, 5, 0], [0xF0, 5, 127, 5], [127, 5, 127, 0xF7], [6, 64], [0xBF, 5, 127]]
        let first = MIDI1Event.channel(status: 0xBF, data1: 5, data2: 0)
        let last = MIDI1Event.channel(status: 0xBF, data1: 5, data2: 127)
        let actions: [LaunchControlXLAction] = [.fader(slot: 0, value: 0), .fader(slot: 0, value: 1)]

        var stream = try LaunchControlXLStream.make()
        let source = try #require(stream.snapshot.sources.first)
        #expect(source.profile.maximumSysExPayloadBytes == MIDISourceProfile.defaultSysExPayloadBytes)
        let outputs = stream.feed(packets: packets)
        #expect(outputs.map(\.event) == [first, .sysEx(payload: [5, 127, 5, 127, 5, 127]), last])
        #expect(mapping.actions(for: outputs) == actions)

        let small = try MIDISourceProfile.make(statePolicy: .unpaired, maximumSysExPayloadBytes: 4)
        var bounded = try LaunchControlXLStream.make(profile: small)
        let boundedOutputs = bounded.feed(packets: packets)
        #expect(boundedOutputs.map(\.event) == [first, last])
        #expect(mapping.actions(for: boundedOutputs) == actions)
        #expect(bounded.snapshot.sources.map(\.state) == stream.snapshot.sources.map(\.state))
    }

    /// T3: fragments that are incomplete, or data bytes with no running status, emit nothing and change no state;
    /// stray EOX and undefined F4/F5 are system events that change no state. A following status byte starts fresh.
    @Test func malformedFragmentsLeaveSnapshotEqual() throws {
        let mapping = try Self.bundledMapping()
        let seed: [UInt8] = [0xBF, 6, 64, 0xF6]
        let silent: [[UInt8]] = [[0xBF, 5], [0xF2, 0], [0xF1], [0x90], [0x90, 60], [5, 127], [0xF0, 5, 127]]
        let systemOnly: [[UInt8]] = [[0xF7], [0xF4], [0xF5]]
        for fragment in silent + systemOnly {
            var stream = try LaunchControlXLStream.make()
            _ = stream.feed(packets: [seed])
            let before = stream.snapshot
            let outputs = stream.feed(packets: [fragment])
            #expect(outputs.isEmpty == silent.contains(fragment), "fragment \(fragment)")
            #expect(mapping.actions(for: outputs).isEmpty, "fragment \(fragment)")
            #expect(stream.snapshot == before, "fragment \(fragment)")
            let next = stream.feed(packets: [[0xBF, 5, 127]])
            #expect(mapping.actions(for: next) == [.fader(slot: 0, value: 1)], "fragment \(fragment)")
            #expect(try Self.channel16(6, in: stream) == 64, "fragment \(fragment)")
        }
    }

    /// T4: System Reset follows the injected profile. Under `.ignore` FF is transparent real time, even inside a
    /// half message; under `.resetSource` it clears the controllers and the half message.
    @Test func systemResetFollowsInjectedProfile() throws {
        let mapping = try Self.bundledMapping()
        var ignoring = try LaunchControlXLStream.make()
        #expect(try #require(ignoring.snapshot.sources.first).profile.systemReset == .ignore)
        let ignored = ignoring.feed(packets: [[0xBF, 5, 100], [0xFF], [0xBF, 6], [0xFF], [127]])
        #expect(try Self.channel16(5, in: ignoring) == 100)
        #expect(mapping.actions(for: ignored) == [.fader(slot: 0, value: 100 / 127), .fader(slot: 1, value: 1)])

        let resetting = try MIDISourceProfile.make(statePolicy: .unpaired, systemReset: .resetSource)
        var stream = try LaunchControlXLStream.make(profile: resetting)
        let outputs = stream.feed(packets: [[0xBF, 5, 100], [0xFF], [0xBF, 6], [0xFF], [127]])
        #expect(try Self.channel16(5, in: stream) == 0)
        #expect(outputs.map(\.outcome).filter { $0 == .systemReset(released: []) }.count == 2)
        #expect(mapping.actions(for: outputs) == [.fader(slot: 0, value: 100 / 127)])
    }

    /// T5: the message shim feeds exactly the bytes of each valid CC and drops channels outside 1...16 and data
    /// bytes of 0x80 or more.
    @Test func messageShimMatchesBytesAndDropsInvalid() throws {
        func control(_ channel: Int, _ controller: UInt8, _ value: UInt8) -> MIDIControlChange {
            MIDIControlChange(channel: channel, controller: controller, value: value)
        }
        let valid = [control(16, 5, 127), control(1, 0, 0), control(16, 64, 100), control(9, 119, 1)]
        let validBytes: [[UInt8]] = [[0xBF, 5, 127], [0xB0, 0, 0], [0xBF, 64, 100], [0xB8, 119, 1]]
        let invalid = [
            control(0, 5, 127), control(17, 5, 127), control(-1, 5, 127), control(16, 0x80, 1), control(16, 5, 0x80),
            control(16, 0xFF, 0xFF)
        ]
        #expect(valid.map { LaunchControlXLStream.bytes(of: $0) } == validBytes.map(Optional.some))
        for message in invalid {
            #expect(LaunchControlXLStream.bytes(of: message) == nil, "\(message)")
        }

        var bytePath = try LaunchControlXLStream.make()
        let byteOutputs = bytePath.feed(packets: validBytes)
        var shim = try LaunchControlXLStream.make()
        let mixed = zip(valid, invalid).flatMap { [$1, $0] } + invalid.dropFirst(valid.count)
        let shimOutputs = shim.feed(mixed)
        #expect(byteOutputs.count == valid.count)
        #expect(shimOutputs == byteOutputs)
        #expect(shim.snapshot == bytePath.snapshot)
    }

    /// T8: one source, bounded at CoreMIDI's `UInt16` length; a longer packet is refused whole, the longest consumed.
    @Test func oversizePacketConsumesNothing() throws {
        let mapping = try Self.bundledMapping()
        #expect(LaunchControlXLStream.maximumPacketBytes == 65_535)
        var stream = try LaunchControlXLStream.make()
        #expect(stream.snapshot.maximumSources == 1)
        #expect(stream.snapshot.maximumFeedBytes == 65_535)
        #expect(stream.snapshot.sources.count == 1)
        let source = try #require(stream.snapshot.sources.first)
        #expect(source.input == LaunchControlXLStream.input)
        #expect(source.profile == LaunchControlXLMapping.sourceProfile)
        #expect(stream.feed(packets: [[0xBF, 5]]).isEmpty)
        let before = stream.snapshot
        #expect(stream.feed(packets: [Array(repeating: 0x7F, count: 65_536)]).isEmpty)
        #expect(stream.snapshot == before)
        let next = stream.feed(packets: [Array(repeating: 0x7F, count: 70_000), [0x7F]])
        #expect(mapping.actions(for: next) == [.fader(slot: 0, value: 1)])

        var longest = try LaunchControlXLStream.make()
        let outputs = longest.feed(packets: [[0xBF] + Array(repeating: 0, count: 65_534)])
        #expect(outputs.count == 32_767)
        #expect(try Self.channel16(0, in: longest) == 0)
    }
}

/// Controller tests: the controller owns one stream, fresh on every restart, and dispatches only after a batch.
extension LaunchControlXLTests {
    @MainActor
    static func streamController(
        _ fixture: LaunchControlXLFixture
    ) -> (LaunchControlXLController, () -> [LaunchControlXLAction]) {
        let controller = fixture.controller(makeMIDIInput: { InertLaunchControlXLInput() })
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }
        return (controller, { dispatched })
    }

    /// T6: a half message never crosses a restart.
    @MainActor
    @Test func restartDropsAPendingHalfMessage() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let (controller, dispatched) = Self.streamController(fixture)
        await controller.load()

        await controller.receive(packets: [[0xBF, 5]])
        await controller.receive(packets: [[0x7F]])
        #expect(dispatched() == [.fader(slot: 0, value: 1)])

        await controller.receive(packets: [[0xBF, 6]])
        await controller.setMode(.control)
        await controller.receive(packets: [[0x7F]])
        #expect(dispatched() == [.fader(slot: 0, value: 1)])
        #expect(controller.lastAction == .fader(slot: 0, value: 1))
        await controller.setMode(.disabled)
    }

    /// T7: the whole batch is applied before the first dispatch: a packet fed from inside the first dispatch lands
    /// after the batch's trailing half message, and the batch's actions keep packet order.
    @MainActor
    @Test func packetsDispatchAfterWholeBatchInOrder() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let controller = fixture.controller(makeMIDIInput: { InertLaunchControlXLInput() })
        await controller.load()
        var dispatched: [LaunchControlXLAction] = []
        var fedInside = false
        controller.setActionHandler { action in
            dispatched.append(action)
            guard !fedInside else { return }
            fedInside = true
            await controller.receive(packets: [[64]])
        }

        await controller.receive(packets: [[0xBF, 5, 127], [6]])
        #expect(dispatched == [.fader(slot: 0, value: 1), .fader(slot: 1, value: 64 / 127)])

        dispatched = []
        await controller.receive(packets: [[0xBF, 45], [127, 0xF8, 5], [0], [102, 127]])
        #expect(dispatched == [.toggleMute(slot: 0), .fader(slot: 0, value: 0), .moveBank(1)])
        controller.setActionHandler { _ in }
        await controller.setMode(.disabled)
    }
}

/// Delivery tests: one ordered path per input start, and nothing from an earlier start reaches the stream.
extension LaunchControlXLTests {
    /// T9: a delivery held from the first start and invoked after a restart never reaches the new stream.
    @MainActor
    @Test func staleDeliveryIsDroppedAfterRestart() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = RecordingLaunchControlXLInput()
        let controller = fixture.controller(makeMIDIInput: { input })
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }
        await controller.load()
        let old = try #require(input.onPackets)
        await controller.setMode(.control)
        let new = try #require(input.onPackets)
        #expect(input.starts.count == 2)

        old([[0xBF, 5]])
        new([[0x7F]])
        old([[0xBF, 6, 0x7F]])
        new([[5, 0x7F]])
        await controller.dispatchPendingActions()
        #expect(dispatched.isEmpty)
        #expect(controller.lastAction == nil)

        new([[0xBF, 5], [0x7F]])
        await controller.dispatchPendingActions()
        #expect(dispatched == [.fader(slot: 0, value: 1)])
        await controller.setMode(.disabled)
    }

    /// T10: split CCs yielded from other threads, all buffered while the main actor is busy, are handled in yield
    /// order; past the bound the newest batch is dropped. Each yield is awaited before the next, so the varying
    /// priorities cannot reorder them: this pins the stream's FIFO buffer and its single consumer.
    @MainActor
    @Test func packetDeliveryKeepsYieldOrder() async throws {
        let mapping = try Self.bundledMapping()
        let packets: [[UInt8]] = (0..<200).flatMap { index in [[0xBF, 5], [UInt8(index % 128)]] }
        var handled: [[UInt8]] = []
        var stream = try LaunchControlXLStream.make()
        var outputs: [MIDISourceOutput] = []
        let delivery = MIDIPacketDelivery { batch in
            handled += batch
            outputs += stream.feed(packets: batch)
        }
        let yielded = YieldCount()
        let producer = Task.detached {
            for (index, packet) in packets.enumerated() {
                let priority: TaskPriority = index.isMultiple(of: 2) ? .low : .high
                _ = await Task.detached(priority: priority) { delivery.yield([packet]) }.value
                yielded.increment()
            }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while yielded.value < packets.count {
            guard ContinuousClock.now < deadline else {
                Issue.record("Only \(yielded.value) of \(packets.count) batches were yielded before the deadline")
                break
            }
        }
        await producer.value
        await delivery.finish()
        #expect(handled == packets)
        let expected = (0..<200).map { LaunchControlXLAction.fader(slot: 0, value: Float($0 % 128) / 127) }
        #expect(mapping.actions(for: outputs) == expected)

        var bounded: [[UInt8]] = []
        let small = MIDIPacketDelivery(maximumPendingBatches: 2) { bounded += $0 }
        #expect(small.yield([[0xBF, 5]]))
        #expect(small.yield([[0x7F]]))
        #expect(!small.yield([[0xBF, 6, 0x7F]]))
        await small.finish()
        #expect(bounded == [[0xBF, 5], [0x7F]])
    }

    /// T11: once `cancel()` returns, nothing is handled, including batches accepted before it.
    @MainActor
    @Test func cancelledPacketDeliveryHandlesNothing() async {
        var handled: [[UInt8]] = []
        let delivery = MIDIPacketDelivery { handled += $0 }
        #expect(delivery.yield([[0xBF, 5]]))
        #expect(delivery.yield([[0x7F]]))
        delivery.cancel()
        #expect(!delivery.yield([[0xBF, 6, 0x7F]]))
        await delivery.finish()
        #expect(handled.isEmpty)
    }

    /// T12: an action fed in Monitor is never dispatched, even when Control is set before the drain reaches it; a
    /// restart also discards actions queued behind a suspended handler.
    @MainActor
    @Test func actionsQueuedBeforeControlOrRestartAreNeverDispatched() async throws {
        let fixture = try LaunchControlXLFixture(mode: .monitor)
        defer { fixture.cleanUp() }
        let input = RecordingLaunchControlXLInput()
        let controller = fixture.controller(makeMIDIInput: { input })
        var dispatched: [LaunchControlXLAction] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdNext = false
        controller.setActionHandler { action in
            dispatched.append(action)
            guard holdNext else { return }
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        await controller.load()
        let monitor = try #require(input.onPackets)
        monitor([[0xBF, 5, 127]])
        await controller.setMode(.control)
        await controller.dispatchPendingActions()
        #expect(dispatched.isEmpty)

        holdNext = true
        let held = Task { await controller.receive(packets: [[0xBF, 5, 127]]) }
        guard await Self.waitUntil({ gate != nil }) else { return }
        await controller.receive(packets: [[0xBF, 6, 127]])
        await controller.setMode(.control)
        gate?.resume()
        await held.value
        #expect(dispatched == [.fader(slot: 0, value: 1)])
        #expect(controller.lastAction == .fader(slot: 0, value: 1))
        await controller.setMode(.disabled)
    }

    /// T13: a receive while a handler is suspended only queues; the running drain dispatches it after the first
    /// handler returns, so handlers never overlap.
    @MainActor
    @Test func receiveDuringSuspendedHandlerOnlyQueues() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let controller = fixture.controller(makeMIDIInput: { InertLaunchControlXLInput() })
        await controller.load()
        var log: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdNext = true
        controller.setActionHandler { action in
            log.append("start \(action)")
            if holdNext {
                holdNext = false
                await withCheckedContinuation { gate = $0 }
            }
            log.append("end \(action)")
        }

        let held = Task { await controller.receive(packets: [[0xBF, 5, 127]]) }
        guard await Self.waitUntil({ gate != nil }) else { return }
        await controller.receive(packets: [[0xBF, 6, 127]])
        #expect(log.count == 1)
        gate?.resume()
        await held.value
        let first = LaunchControlXLAction.fader(slot: 0, value: 1)
        let second = LaunchControlXLAction.fader(slot: 1, value: 1)
        #expect(log == ["start \(first)", "end \(first)", "start \(second)", "end \(second)"])
        controller.setActionHandler { _ in }
        await controller.setMode(.disabled)
    }

    /// Lets other main-actor work run until `condition` holds; records an issue and returns false after `limit`.
    @MainActor
    static func waitUntil(_ condition: () -> Bool, limit: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out after \(limit)")
                return false
            }
            await Task.yield()
        }
        return true
    }
}

/// How many batches T10's producer has yielded, read by the busy main actor.
private final class YieldCount: Sendable {
    private let count = Atomic<Int>(0)

    var value: Int { count.load(ordering: .acquiring) }

    func increment() {
        count.add(1, ordering: .releasing)
    }
}
