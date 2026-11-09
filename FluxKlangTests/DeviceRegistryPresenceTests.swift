import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct DeviceRegistryPresenceTests {
    private struct FixtureFailure: Error {}

    private enum Scenario {
        case present
        case lost
        case revalidating
        case mismatchBuffer
        case mismatchLayout
        case noBaseline
    }

    private static let audioCapability = CapabilityID(validated: "cap.audio")

    private static let thousandAndOne: [DeviceRecord] = (1...1_025).compactMap {
        try? DeviceRegistryPresenceTests.record($0)
    }

    // MARK: Mapping

    @Test func deviceRegistryPresenceReportsAPresentDeviceAsPresent() throws {
        let projection = try DeviceRegistryPresence.make(registry: Self.registry([.present]))
        let expected = try Self.golden([(1, .present)])
        #expect(projection.byDevice == expected)
        let present = projection.gate.present
        let lost = projection.gate.lost
        let revalidating = projection.gate.revalidating
        let muted = projection.gate.muted
        #expect(present == 1)
        #expect(lost == 0)
        #expect(revalidating == 0)
        #expect(muted == 0)
    }

    @Test func deviceRegistryPresenceReportsALostDeviceAsMissing() throws {
        let projection = try DeviceRegistryPresence.make(registry: Self.registry([.lost]))
        let expected = try Self.golden([(1, .missing)])
        #expect(projection.byDevice == expected)
        let present = projection.gate.present
        let lost = projection.gate.lost
        let revalidating = projection.gate.revalidating
        let muted = projection.gate.muted
        #expect(present == 0)
        #expect(lost == 1)
        #expect(revalidating == 0)
        #expect(muted == 0)
    }

    @Test func deviceRegistryPresenceReportsARevalidatingDeviceAsStale() throws {
        let projection = try DeviceRegistryPresence.make(registry: Self.registry([.revalidating]))
        let expected = try Self.golden([(1, .stale)])
        #expect(projection.byDevice == expected)
        let present = projection.gate.present
        let lost = projection.gate.lost
        let revalidating = projection.gate.revalidating
        let muted = projection.gate.muted
        #expect(present == 0)
        #expect(lost == 0)
        #expect(revalidating == 1)
        #expect(muted == 0)
    }

    @Test func deviceRegistryPresenceReportsAMutedCapabilityMismatchAsStale() throws {
        let registry = try Self.registry([.mismatchBuffer])
        let first = try #require(registry.records.first)
        #expect(first.lifecycle == .muted(.capabilityMismatch(.bufferFrames)))
        let projection = try DeviceRegistryPresence.make(registry: registry)
        let expected = try Self.golden([(1, .stale)])
        #expect(projection.byDevice == expected)
        let present = projection.gate.present
        let lost = projection.gate.lost
        let revalidating = projection.gate.revalidating
        let muted = projection.gate.muted
        #expect(present == 0)
        #expect(lost == 0)
        #expect(revalidating == 0)
        #expect(muted == 1)
    }

    @Test func deviceRegistryPresenceReportsAMutedNoBaselineDeviceAsStale() throws {
        let registry = try Self.registry([.noBaseline])
        let first = try #require(registry.records.first)
        #expect(first.lifecycle == .muted(.noMeasuredBaseline))
        let projection = try DeviceRegistryPresence.make(registry: registry)
        let expected = try Self.golden([(1, .stale)])
        #expect(projection.byDevice == expected)
        let present = projection.gate.present
        let lost = projection.gate.lost
        let revalidating = projection.gate.revalidating
        let muted = projection.gate.muted
        #expect(present == 0)
        #expect(lost == 0)
        #expect(revalidating == 0)
        #expect(muted == 1)
    }

    @Test func deviceRegistryPresenceReportsTwoDifferentMismatchFieldsAlike() throws {
        let buffer = try Self.registry([.mismatchBuffer])
        let layout = try Self.registry([.mismatchLayout])
        let bufferFirst = try #require(buffer.records.first)
        let layoutFirst = try #require(layout.records.first)
        #expect(bufferFirst.lifecycle == .muted(.capabilityMismatch(.bufferFrames)))
        #expect(layoutFirst.lifecycle == .muted(.capabilityMismatch(.layout)))
        let bufferProjection = try DeviceRegistryPresence.make(registry: buffer)
        let layoutProjection = try DeviceRegistryPresence.make(registry: layout)
        #expect(bufferProjection == layoutProjection)
        let device = try Self.deviceID(1)
        let state = bufferProjection.presence(of: device)
        #expect(state == .stale)
    }

    @Test func deviceRegistryPresenceMapsEveryLifecycleValueByTheLifecycleAlone() {
        let present = DeviceRegistryPresence.presence(of: DeviceLifecycle.present)
        let lost = DeviceRegistryPresence.presence(of: DeviceLifecycle.lostMuted)
        let revalidating = DeviceRegistryPresence.presence(of: DeviceLifecycle.revalidating)
        #expect(present == .present)
        #expect(lost == .missing)
        #expect(revalidating == .stale)
        var mutedStates: [DevicePresence] = [
            DeviceRegistryPresence.presence(of: .muted(.noMeasuredBaseline))
        ]
        for field in DeviceCapabilityField.allCases {
            mutedStates.append(DeviceRegistryPresence.presence(of: .muted(.capabilityMismatch(field))))
        }
        let allStale = mutedStates.allSatisfy { $0 == .stale }
        #expect(mutedStates.count == 5)
        #expect(allStale)
    }

    // MARK: Gate

    @Test func deviceRegistryPresenceCountsAMixedRegistryAndMatchesTheRegistryGate() throws {
        let registry = try Self.registry([.present, .lost, .revalidating, .mismatchBuffer, .noBaseline, .present])
        let projection = try DeviceRegistryPresence.make(registry: registry)
        let expected = try Self.golden([
            (1, .present), (2, .missing), (3, .stale), (4, .stale), (5, .stale), (6, .present)
        ])
        #expect(projection.byDevice == expected)
        let present = projection.gate.present
        let lost = projection.gate.lost
        let revalidating = projection.gate.revalidating
        let muted = projection.gate.muted
        let total = projection.gate.total
        let blocked = projection.gate.blocked
        #expect(present == 2)
        #expect(lost == 1)
        #expect(revalidating == 1)
        #expect(muted == 2)
        #expect(total == 6)
        #expect(blocked == 4)
        let allows = projection.gate.allowsEngineAcquisition
        let registryAllows = registry.allowsEngineAcquisition
        #expect(!allows)
        #expect(allows == registryAllows)
        let mapCount = projection.byDevice.count
        #expect(total == mapCount)
    }

    @Test func deviceRegistryPresenceGateAgreesWithTheRegistryForEachBlockedStateAlone() throws {
        let blockedScenarios: [Scenario] = [.lost, .revalidating, .mismatchBuffer, .noBaseline]
        for scenario in blockedScenarios {
            let registry = try Self.registry([scenario])
            let projection = try DeviceRegistryPresence.make(registry: registry)
            let allows = projection.gate.allowsEngineAcquisition
            let registryAllows = registry.allowsEngineAcquisition
            let blocked = projection.gate.blocked
            #expect(!allows)
            #expect(allows == registryAllows)
            #expect(blocked == 1)
        }
    }

    @Test func deviceRegistryPresenceAnEmptyOrAllPresentRegistryAllowsAcquisition() throws {
        let empty = try DeviceRegistryPresence.make(records: [])
        let emptyAllows = empty.gate.allowsEngineAcquisition
        let emptyTotal = empty.gate.total
        #expect(empty.byDevice.isEmpty)
        #expect(emptyTotal == 0)
        #expect(emptyAllows)
        #expect(emptyAllows == DeviceRegistry.empty.allowsEngineAcquisition)
        #expect(empty.gate == DeviceRegistryPresenceGate.none)

        let registry = try Self.registry([.present, .present, .present])
        let projection = try DeviceRegistryPresence.make(registry: registry)
        let allows = projection.gate.allowsEngineAcquisition
        let blocked = projection.gate.blocked
        let total = projection.gate.total
        #expect(allows)
        #expect(allows == registry.allowsEngineAcquisition)
        #expect(blocked == 0)
        #expect(total == 3)
    }

    // MARK: Lookup and order

    @Test func deviceRegistryPresenceLooksUpAKnownDeviceAndReturnsNilForAnUnknownOne() throws {
        let projection = try DeviceRegistryPresence.make(registry: Self.registry([.present, .lost]))
        let known = projection.presence(of: try Self.deviceID(2))
        #expect(known == .missing)
        let unknown = projection.presence(of: try Self.deviceID(3))
        #expect(unknown == nil)
    }

    @Test func deviceRegistryPresenceDoesNotDependOnTheOrderOfTheRecords() throws {
        let registry = try Self.registry([.present, .lost, .revalidating, .mismatchBuffer, .noBaseline, .present])
        let records = registry.records
        try #require(records.count == 6)
        let forward = try DeviceRegistryPresence.make(records: records)
        let reversed = try DeviceRegistryPresence.make(records: records.reversed())
        let shuffled = try DeviceRegistryPresence.make(records: [3, 0, 5, 1, 4, 2].map { records[$0] })
        #expect(forward == reversed)
        #expect(forward == shuffled)
        #expect(forward.byDevice.count == 6)
    }

    @Test func deviceRegistryPresenceFromARegistryEqualsFromItsRecords() throws {
        let registry = try Self.registry([.present, .lost, .revalidating, .mismatchLayout, .noBaseline])
        let fromRegistry = try DeviceRegistryPresence.make(registry: registry)
        let fromRecords = try DeviceRegistryPresence.make(records: registry.records)
        #expect(fromRegistry == fromRecords)
        #expect(fromRegistry.byDevice.count == 5)
    }

    // MARK: Limits and refusals

    @Test func deviceRegistryPresenceAcceptsTheLimitAndRefusesOneMore() throws {
        #expect(Self.thousandAndOne.count == 1_025)
        let limit = Array(Self.thousandAndOne.prefix(1_024))
        let accepted = try DeviceRegistryPresence.make(records: limit)
        let acceptedTotal = accepted.gate.total
        #expect(accepted.byDevice.count == 1_024)
        #expect(acceptedTotal == 1_024)
        #expect(throws: DeviceRegistryRefusal.tooManyDevices(count: 1_025, maximum: 1_024)) {
            _ = try DeviceRegistryPresence.make(records: Self.thousandAndOne)
        }
    }

    @Test func deviceRegistryPresenceReportsTooManyDevicesBeforeADuplicateId() throws {
        let repeated = try Self.record(1_026, id: try Self.deviceID(1))
        let both = Self.thousandAndOne + [repeated]
        #expect(both.count == 1_026)
        #expect(throws: DeviceRegistryRefusal.tooManyDevices(count: 1_026, maximum: 1_024)) {
            _ = try DeviceRegistryPresence.make(records: both)
        }
    }

    @Test func deviceRegistryPresenceRefusesARepeatedDeviceIdEvenWithDifferentUIDs() throws {
        let first = try Self.record(1)
        let second = try Self.record(2, id: try Self.deviceID(1))
        #expect(first.identityKey != second.identityKey)
        let expected = DeviceRegistryRefusal.duplicateDeviceID(try Self.deviceID(1))
        #expect(throws: expected) {
            _ = try DeviceRegistryPresence.make(records: [first, second])
        }
    }

    @Test func deviceRegistryPresenceKeepsTwoDeviceIdsThatShareOneIdentityKey() throws {
        let first = try Self.record(1)
        let second = try Self.record(1, id: try Self.deviceID(2))
        #expect(first.identityKey == second.identityKey)
        let projection = try DeviceRegistryPresence.make(records: [first, second])
        let expected = try Self.golden([(1, .present), (2, .present)])
        let total = projection.gate.total
        #expect(projection.byDevice == expected)
        #expect(total == 2)
    }

    @Test func deviceRegistryPresenceNamesTheIdWhoseRepeatComesFirstInInputOrder() throws {
        let aFirst = try Self.record(1)
        let bFirst = try Self.record(2)
        let aRepeat = try Self.record(11, id: try Self.deviceID(1))
        let bRepeat = try Self.record(12, id: try Self.deviceID(2))
        let namesB = DeviceRegistryRefusal.duplicateDeviceID(try Self.deviceID(2))
        let namesA = DeviceRegistryRefusal.duplicateDeviceID(try Self.deviceID(1))
        #expect(throws: namesB) {
            _ = try DeviceRegistryPresence.make(records: [aFirst, bFirst, bRepeat, aRepeat])
        }
        #expect(throws: namesA) {
            _ = try DeviceRegistryPresence.make(records: [aFirst, bFirst, aRepeat, bRepeat])
        }
    }

    // MARK: Sources

    @Test(.enabled(if: !DeviceRegistryPresenceTests.productionSources().isEmpty))
    func deviceRegistryPresenceSourcesNameNoBannedTimeConcurrencyCatchAllOrMutableStateToken() {
        let texts = Self.productionSources()
        #expect(texts.count == 2)
        let banned = ["Ta" + "sk", "Clo" + "ck", "Da" + "te", "defa" + "ult:", "try" + "!", "static " + "var",
                      "mutat" + "ing", "Cod" + "able", "FileMan" + "ager", "Dou" + "ble"]
        for text in texts {
            for token in banned { #expect(!text.contains(token)) }
        }
    }

    private static func productionSources() -> [String] {
        let names = ["DeviceRegistryPresence.swift", "DeviceRegistryPresenceGate.swift"]
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Audio/Devices/Registry/Presence/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = names.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == names.count { return texts }
        }
        return []
    }

    // MARK: Fixtures

    private static func deviceID(_ index: Int) throws -> DeviceID {
        try DeviceID("dev.\(index)")
    }

    private static func golden(_ pairs: [(Int, DevicePresence)]) throws -> [DeviceID: DevicePresence] {
        var result: [DeviceID: DevicePresence] = [:]
        for (index, state) in pairs { result[try deviceID(index)] = state }
        return result
    }

    private static func record(
        _ index: Int, id: DeviceID? = nil, measured: DeviceCapabilitySet? = nil
    ) throws -> DeviceRecord {
        try DeviceRecord.make(
            id: try id ?? deviceID(index),
            kind: .audioInterface,
            identity: DeviceIdentityFields(uid: "uid.\(index)", evidence: [.deviceUID]),
            reportedCapabilities: DeviceCapabilitySet.make(capabilities: [audioCapability]),
            measuredCapabilities: measured
        )
    }

    private static func measuredSet(
        bufferFrames: Int = 128, inputs: Int = 2
    ) throws -> DeviceCapabilitySet {
        try DeviceCapabilitySet.make(
            capabilities: [audioCapability],
            layout: ChannelLayout(inputs: inputs, outputs: 2, sampleRate: 48_000),
            actualRate: MeasuredRate(MeasuredRateFields(hertz: 48_000, evidence: "readback.48k")),
            bufferFrames: bufferFrames
        )
    }

    private static func step(_ registry: DeviceRegistry, _ event: DeviceRegistryEvent) throws -> DeviceRegistry {
        guard case .accepted(let next, _) = registry.applying(event) else { throw FixtureFailure() }
        return next
    }

    private static func registry(_ scenarios: [Scenario]) throws -> DeviceRegistry {
        var registry = DeviceRegistry.empty
        for (offset, scenario) in scenarios.enumerated() {
            registry = try adding(scenario, index: offset + 1, to: registry)
        }
        return registry
    }

    private static func adding(
        _ scenario: Scenario, index: Int, to registry: DeviceRegistry
    ) throws -> DeviceRegistry {
        let baseline = try measuredSet()
        switch scenario {
        case .present:
            return try step(registry, .observed(record(index, measured: baseline)))
        case .lost:
            let record = try record(index, measured: baseline)
            return try step(step(registry, .observed(record)), .disappeared(record.identityKey))
        case .revalidating:
            return try revalidating(index, baseline: baseline, in: registry).registry
        case .mismatchBuffer:
            let next = try revalidating(index, baseline: baseline, in: registry)
            let changed = try measuredSet(bufferFrames: 256)
            return try step(next.registry, .capabilitiesMeasured(next.key, changed))
        case .mismatchLayout:
            let next = try revalidating(index, baseline: baseline, in: registry)
            let changed = try measuredSet(inputs: 4)
            return try step(next.registry, .capabilitiesMeasured(next.key, changed))
        case .noBaseline:
            let next = try revalidating(index, baseline: nil, in: registry)
            return try step(next.registry, .capabilitiesMeasured(next.key, baseline))
        }
    }

    private static func revalidating(
        _ index: Int, baseline: DeviceCapabilitySet?, in registry: DeviceRegistry
    ) throws -> (registry: DeviceRegistry, key: DeviceIdentityKey) {
        let record = try record(index, measured: baseline)
        let observed = try step(registry, .observed(record))
        let lost = try step(observed, .disappeared(record.identityKey))
        return (try step(lost, .returned(record.identityKey)), record.identityKey)
    }
}
