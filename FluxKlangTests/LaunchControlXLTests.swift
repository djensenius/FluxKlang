//
//  LaunchControlXLTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct LaunchControlXLTests {
    @Test func bundledMappingMatchesLaunchControlXL3DefaultMode16() throws {
        let configuration = try #require(LaunchControlXLConfiguration.bundled())

        #expect(configuration.mode == .monitor)
        #expect(configuration.mapping.channel == 16)
        #expect(configuration.mapping.faderCCs == Array(5...12))
        #expect(configuration.mapping.panOrBalanceCCs == Array(13...20))
        #expect(configuration.mapping.selectCCs == Array(37...44))
        #expect(configuration.mapping.muteCCs == Array(45...52))
        #expect(configuration.mapping.bankPreviousCC == 103)
        #expect(configuration.mapping.bankNextCC == 102)
    }

    @Test func mappingResolvesContinuousButtonsAndBanks() throws {
        let mapping = try #require(LaunchControlXLConfiguration.bundled()).mapping

        #expect(mapping.action(for: .init(channel: 16, controller: 5, value: 127)) == .fader(
            slot: 0,
            value: 1
        ))
        #expect(mapping.action(for: .init(channel: 16, controller: 20, value: 0)) == .panOrBalance(
            slot: 7,
            value: -1
        ))
        #expect(mapping.action(for: .init(channel: 16, controller: 45, value: 127)) == .toggleMute(slot: 0))
        #expect(mapping.action(for: .init(channel: 16, controller: 45, value: 0)) == nil)
        #expect(mapping.action(for: .init(channel: 16, controller: 102, value: 127)) == .moveBank(1))
        #expect(mapping.action(for: .init(channel: 1, controller: 5, value: 127)) == nil)
    }

    @Test func midiDecoderHandlesChannel16AndRunningStatus() {
        #expect(MIDIControlChange.decode([0xBF, 5, 127, 6, 64]) == [
            MIDIControlChange(channel: 16, controller: 5, value: 127),
            MIDIControlChange(channel: 16, controller: 6, value: 64)
        ])
    }

    @MainActor
    @Test func monitorModeNeverDispatchesControlActions() async throws {
        var configuration = try #require(LaunchControlXLConfiguration.bundled())
        configuration.mode = .monitor
        let controller = LaunchControlXLController(defaultConfiguration: configuration)
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }

        await controller.receive([MIDIControlChange(channel: 16, controller: 5, value: 127)])

        #expect(controller.lastAction == .fader(slot: 0, value: 1))
        #expect(dispatched.isEmpty)
    }

    @MainActor
    @Test func controlModeDispatchesAndClampsBanks() async throws {
        var configuration = try #require(LaunchControlXLConfiguration.bundled())
        configuration.mode = .control
        let controller = LaunchControlXLController(defaultConfiguration: configuration)
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }

        await controller.receive([MIDIControlChange(channel: 16, controller: 45, value: 127)])
        controller.moveBank(1, stripCount: 18)
        controller.moveBank(10, stripCount: 18)

        #expect(dispatched == [.toggleMute(slot: 0)])
        #expect(controller.bank == 2)
        #expect(controller.stripIndex(for: 3) == 19)
    }

    @MainActor
    @Test func appModelAppliesControlActionsThroughWingController() async throws {
        let wing = WingController.preview()
        let model = AppModel(wing: wing)
        let writesBefore = wing.transportWriteCount

        await model.handleLaunchControlXL(.fader(slot: 0, value: 0.25))

        #expect(wing.transportWriteCount == writesBefore + 2)
        let left = try #require(wing.faderPosition(.channel, 1))
        let right = try #require(wing.faderPosition(.channel, 2))
        #expect(abs((left + right) / 2 - 0.25) < 0.0001)
        #expect(abs((right - left) + 0.06) < 0.0001)
    }
}
