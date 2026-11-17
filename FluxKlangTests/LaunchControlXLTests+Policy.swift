//
//  LaunchControlXLTests+Policy.swift
//  FluxKlangTests
//

import Foundation
import Testing
@testable import FluxKlang

/// The Launch Control XL source policy (#80, slice MU5): an injected, validated profile and the opt-in sender
/// cleanup. The default must read the surface exactly as before. Synthetic bytes only; nothing starts CoreMIDI.
extension LaunchControlXLTests {
    /// Lone CC 6 (refused under `.standard`), CC 5, and FF inside a half message (a reset under `.resetSource`).
    static let policyPackets: [[UInt8]] = [[0xBF, 6, 127], [0xBF, 5, 100], [0xFF], [0xBF, 6], [0xFF], [127]]
    static let policyActions: [LaunchControlXLAction] = [
        .fader(slot: 1, value: 1), .fader(slot: 0, value: 100 / 127), .fader(slot: 1, value: 1)
    ]

    @MainActor
    private static func policyController(
        _ fixture: LaunchControlXLFixture, input: SourcesRecordingInput = SourcesRecordingInput(),
        policy: LaunchControlXLSourcePolicy
    ) -> (LaunchControlXLController, () -> [LaunchControlXLAction]) {
        let controller = LaunchControlXLController(
            fileStore: fixture.store, defaultConfiguration: fixture.configuration, makeMIDIInput: { input },
            sourcePolicy: policy
        )
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }
        return (controller, { dispatched })
    }

    /// P1: the default is today's profile (`.unpaired`, 4,096-byte SysEx bound, System Reset ignored), on a stream
    /// of one source bounded at 65,535 bytes, and it keeps the stream when the sources change.
    @Test func defaultPolicyIsTodaysProfile() throws {
        let policy = LaunchControlXLSourcePolicy.default
        #expect(policy.sourceChange == .keep)
        #expect(policy.profile == .unpaired)
        #expect(policy.profile == LaunchControlXLMapping.sourceProfile)
        #expect(policy.profile.statePolicy == .unpaired)
        #expect(policy.profile.maximumSysExPayloadBytes == 4_096)
        #expect(policy.profile.systemReset == .ignore)
        let stream = try LaunchControlXLStream.make(profile: policy.profile)
        #expect(stream.snapshot.maximumSources == 1)
        #expect(stream.snapshot.maximumFeedBytes == 65_535)
        let source = try #require(stream.snapshot.sources.first)
        #expect(source.profile == policy.profile)
    }

    /// P2: a controller built without a policy uses the default and acts exactly as a bare stream, before and
    /// after a restart.
    @MainActor
    @Test func defaultControllerMatchesBareStream() async throws {
        let mapping = try Self.bundledMapping()
        var bare = try LaunchControlXLStream.make()
        #expect(mapping.actions(for: bare.feed(packets: Self.policyPackets)) == Self.policyActions)

        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let (controller, dispatched) = Self.streamController(fixture)
        #expect(controller.sourcePolicy == .default)
        await controller.receive(packets: Self.policyPackets)
        #expect(dispatched() == Self.policyActions)
        await controller.load()
        await controller.receive(packets: Self.policyPackets)
        #expect(dispatched() == Self.policyActions + Self.policyActions)
        await controller.setMode(.disabled)
    }

    /// P3: an injected `.standard` profile reads the lone CC 6 as Data Entry with no parameter selected, so it
    /// maps to nothing, on init and after every restart; a CC outside the paired ranges still maps.
    @MainActor
    @Test func injectedStandardProfileSurvivesRestart() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let policy = LaunchControlXLSourcePolicy(profile: .standard, sourceChange: .keep)
        let (controller, dispatched) = Self.policyController(fixture, policy: policy)
        let loneDataEntry: [[UInt8]] = [[0xBF, 6, 127]]

        await controller.receive(packets: loneDataEntry)
        #expect(dispatched().isEmpty)
        await controller.load()
        await controller.setMode(.control)
        await controller.receive(packets: loneDataEntry)
        #expect(dispatched().isEmpty)
        await controller.receive(packets: [[0xBF, 102, 127]])
        #expect(dispatched() == [.moveBank(1)])
        await controller.setMode(.disabled)
    }

    /// P4: an injected `.resetSource` profile drops the half message an FF interrupts, on init and after a restart.
    @MainActor
    @Test func injectedResetSourceApplies() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let profile = try MIDISourceProfile.make(statePolicy: .unpaired, systemReset: .resetSource)
        let policy = LaunchControlXLSourcePolicy(profile: profile, sourceChange: .keep)
        let (controller, dispatched) = Self.policyController(fixture, policy: policy)
        let interrupted: [[UInt8]] = [[0xBF, 5], [0xFF], [127]]

        await controller.receive(packets: interrupted)
        #expect(dispatched().isEmpty)
        await controller.load()
        await controller.receive(packets: interrupted)
        #expect(dispatched().isEmpty)
        await controller.receive(packets: [[0xBF, 5, 127]])
        #expect(dispatched() == [.fader(slot: 0, value: 1)])
        await controller.setMode(.disabled)
    }

    /// P5: by default an unplug and replug keep the half message, as before this policy existed.
    @MainActor
    @Test func unplugKeepsHalfMessageByDefault() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = SourcesRecordingInput()
        let (controller, dispatched) = Self.policyController(fixture, input: input, policy: .default)
        await controller.load()
        let report = try #require(input.onSourcesChanged.last)

        report(["LCXL3 MIDI In"])
        await controller.receive(packets: [[0xBF, 5]])
        report([])
        #expect(controller.status == .waiting)
        report(["LCXL3 MIDI In"])
        await controller.receive(packets: [[127]])
        #expect(dispatched() == [.fader(slot: 0, value: 1)])
        #expect(controller.status == .connected(["LCXL3 MIDI In"]))
        await controller.setMode(.disabled)
    }

    /// P6: under `.resetStream` an unplug drops the half message; the next complete message still maps.
    @MainActor
    @Test func unplugResetsWhenOptedIn() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = SourcesRecordingInput()
        let policy = LaunchControlXLSourcePolicy(profile: .unpaired, sourceChange: .resetStream)
        let (controller, dispatched) = Self.policyController(fixture, input: input, policy: policy)
        await controller.load()
        let report = try #require(input.onSourcesChanged.last)

        report(["LCXL3 MIDI In"])
        await controller.receive(packets: [[0xBF, 5]])
        report([])
        #expect(controller.status == .waiting)
        await controller.receive(packets: [[127]])
        #expect(dispatched().isEmpty)
        await controller.receive(packets: [[0xBF, 5, 127]])
        #expect(dispatched() == [.fader(slot: 0, value: 1)])
        await controller.setMode(.disabled)
    }

    /// P7: under `.resetStream` a report of the same names, in any order, resets nothing.
    @MainActor
    @Test func identicalSourceListDoesNotReset() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = SourcesRecordingInput()
        let policy = LaunchControlXLSourcePolicy(profile: .unpaired, sourceChange: .resetStream)
        let (controller, dispatched) = Self.policyController(fixture, input: input, policy: policy)
        await controller.load()
        let report = try #require(input.onSourcesChanged.last)

        report(["LCXL3 A", "LCXL3 B"])
        await controller.receive(packets: [[0xBF, 5]])
        report(["LCXL3 A", "LCXL3 B"])
        report(["LCXL3 B", "LCXL3 A"])
        #expect(controller.status == .connected(["LCXL3 B", "LCXL3 A"]))
        await controller.receive(packets: [[127]])
        #expect(dispatched() == [.fader(slot: 0, value: 1)])
        await controller.setMode(.disabled)
    }

    /// P8: a sources report held from an earlier start neither resets the current stream nor changes the status.
    @MainActor
    @Test func staleStartSourcesCallbackIgnored() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = SourcesRecordingInput()
        let policy = LaunchControlXLSourcePolicy(profile: .unpaired, sourceChange: .resetStream)
        let (controller, dispatched) = Self.policyController(fixture, input: input, policy: policy)
        await controller.load()
        await controller.setMode(.control)
        try #require(input.onSourcesChanged.count == 2)
        let old = try #require(input.onSourcesChanged.first)
        let current = try #require(input.onSourcesChanged.last)

        current(["LCXL3 MIDI In"])
        await controller.receive(packets: [[0xBF, 5]])
        old([])
        old(["Other LCXL3"])
        #expect(controller.status == .connected(["LCXL3 MIDI In"]))
        await controller.receive(packets: [[127]])
        #expect(dispatched() == [.fader(slot: 0, value: 1)])
        await controller.setMode(.disabled)
    }

    /// P9: under `.resetStream` a source joining or leaving while another stays connected also drops the half
    /// message, not only a full unplug; the next complete message still maps.
    @MainActor
    @Test func partialSourceChangesResetWhenOptedIn() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = SourcesRecordingInput()
        let policy = LaunchControlXLSourcePolicy(profile: .unpaired, sourceChange: .resetStream)
        let (controller, dispatched) = Self.policyController(fixture, input: input, policy: policy)
        await controller.load()
        let report = try #require(input.onSourcesChanged.last)
        let fader: [LaunchControlXLAction] = [.fader(slot: 0, value: 1)]

        report(["LCXL3 A"])
        await controller.receive(packets: [[0xBF, 5]])
        report(["LCXL3 A", "LCXL3 B"])
        await controller.receive(packets: [[127]])
        #expect(dispatched().isEmpty)
        await controller.receive(packets: [[0xBF, 5, 127]])
        #expect(dispatched() == fader)

        await controller.receive(packets: [[0xBF, 5]])
        report(["LCXL3 B"])
        #expect(controller.status == .connected(["LCXL3 B"]))
        await controller.receive(packets: [[127]])
        #expect(dispatched() == fader)
        await controller.receive(packets: [[0xBF, 5, 127]])
        #expect(dispatched() == fader + fader)
        await controller.setMode(.disabled)
    }
}

/// Keeps every start's sources callback, so a test can invoke one from an earlier start. Like CoreMIDI, `stop()`
/// reports no sources through the latest callback.
@MainActor
private final class SourcesRecordingInput: LaunchControlXLInput {
    private(set) var onSourcesChanged: [([String]) -> Void] = []

    func start(
        sourceNameContains: [String],
        onPackets: @escaping @MainActor (MIDIPacketBatch) -> Void,
        onSourcesChanged: @escaping ([String]) -> Void
    ) {
        self.onSourcesChanged.append(onSourcesChanged)
    }

    func stop() {
        onSourcesChanged.last?([])
    }
}
