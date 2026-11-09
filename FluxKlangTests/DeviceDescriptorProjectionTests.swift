import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct DeviceDescriptorProjectionTests {
    // One record more than the device cap; the cap test takes prefixes of it.
    private static let capPlusOne: [DeviceRecord] = makeRecords(DeviceCapabilityLimits.devices + 1)

    // MARK: Binding, presence and data source

    @Test func deviceDescriptorProjectionMeasuredPresentDeviceMatchesGolden() throws {
        let layout = try makeLayout(8, rate: 48_000)
        let baseline = try measuredSet([capB, capA, capD], layout: layout)
        let record = try makeRecord(7, kind: .midiController, measured: baseline)
        let output = try DeviceDescriptorProjection.descriptors(records: [record])
        var golden = try DeviceDescriptor(
            id: deviceID(7), kind: .midiController, layout: layout, binding: .measured,
            identity: makeIdentity("uid.7"), presence: .present, evidence: "readback.48k",
            capabilities: [capA, capB, capD]
        )
        golden.actualRate = try makeRate("readback.48k")
        #expect(output == [golden])
    }

    @Test func deviceDescriptorProjectionPresentDeviceWithoutBaselineIsReported() throws {
        let record = try makeRecord(1)
        #expect(record.measuredCapabilities == nil)
        let output = try DeviceDescriptorProjection.descriptors(records: [record])
        let golden = try reportedGolden(1, presence: .present)
        #expect(output == [golden])
    }

    @Test func deviceDescriptorProjectionBaselineWithoutRateIsReportedWithReportedData() throws {
        let layout = try makeLayout(8, rate: 48_000)
        let baseline = try measuredSet([capB, capA, capD], layout: layout, evidence: nil)
        let rate = baseline.actualRate
        #expect(rate == nil)
        let record = try makeRecord(1, measured: baseline)
        let output = try DeviceDescriptorProjection.descriptors(records: [record])
        let golden = try reportedGolden(1, presence: .present)
        #expect(output == [golden])
    }

    @Test func deviceDescriptorProjectionLostDeviceIsMissingAndReportedDespiteBaseline() throws {
        let record = try singleRecord(.lost)
        #expect(record.lifecycle == .lostMuted)
        let baseline = try #require(record.measuredCapabilities)
        let rate = baseline.actualRate
        #expect(rate != nil)
        let output = try DeviceDescriptorProjection.descriptors(records: [record])
        let golden = try reportedGolden(1, presence: .missing)
        #expect(output == [golden])
    }

    @Test func deviceDescriptorProjectionRevalidatingDeviceIsStaleAndReported() throws {
        let record = try singleRecord(.revalidating)
        #expect(record.lifecycle == .revalidating)
        let baseline = try #require(record.measuredCapabilities)
        let rate = baseline.actualRate
        #expect(rate != nil)
        let output = try DeviceDescriptorProjection.descriptors(records: [record])
        let golden = try reportedGolden(1, presence: .stale)
        #expect(output == [golden])
    }

    @Test func deviceDescriptorProjectionMutedDevicesAreStaleAndReported() throws {
        let mismatch = try singleRecord(.mismatch)
        #expect(mismatch.lifecycle == .muted(.capabilityMismatch(.bufferFrames)))
        let baseline = try #require(mismatch.measuredCapabilities)
        let rate = baseline.actualRate
        #expect(rate != nil)
        let noBaseline = try singleRecord(.noBaseline)
        #expect(noBaseline.lifecycle == .muted(.noMeasuredBaseline))
        #expect(noBaseline.measuredCapabilities == nil)
        let golden = try reportedGolden(1, presence: .stale)
        let fromMismatch = try DeviceDescriptorProjection.descriptors(records: [mismatch])
        let fromNoBaseline = try DeviceDescriptorProjection.descriptors(records: [noBaseline])
        #expect(fromMismatch == [golden])
        #expect(fromNoBaseline == [golden])
    }

    @Test func deviceDescriptorProjectionTakesEachBindingFromOneSource() throws {
        let registry = try buildRegistry([.present, .lost])
        let output = try DeviceDescriptorProjection.descriptors(registry: registry)
        try #require(output.count == 2)
        let present = output[0]
        let lost = output[1]
        let baselineLayout = try makeLayout(8, rate: 48_000)
        let reportedLayout = try makeLayout(2, rate: 44_100)
        #expect(present.binding == .measured)
        #expect(present.capabilities == [capA, capB, capD])
        #expect(present.layout == baselineLayout)
        #expect(lost.binding == .reported)
        #expect(lost.capabilities == [capA, capC])
        #expect(lost.layout == reportedLayout)
    }

    @Test func deviceDescriptorProjectionMeasuredBaselineWithoutLayoutOrCapabilitiesStaysEmpty() throws {
        let reported = try DeviceCapabilitySet.make(capabilities: [capAudio], layout: makeLayout(2, rate: 44_100))
        let baseline = try measuredSet([], layout: nil)
        let record = try makeRecord(1, reported: reported, measured: baseline)
        let output = try DeviceDescriptorProjection.descriptors(records: [record])
        let row = try #require(output.first)
        #expect(output.count == 1)
        #expect(row.binding == .measured)
        #expect(row.layout == nil)
        #expect(row.capabilities.isEmpty)
    }

    // MARK: Copied values

    @Test func deviceDescriptorProjectionCopiesIdentityAndEvidenceUnchanged() throws {
        let uids = ["uid.caf\u{E9}", "uid.cafe\u{301}", " uid.pad\t", "uid.shared", "uid.shared"]
        var records: [DeviceRecord] = []
        for (offset, uid) in uids.enumerated() {
            records.append(try makeRecord(offset + 1, uid: uid))
        }
        let output = try DeviceDescriptorProjection.descriptors(records: records)
        #expect(output.count == 5)
        for (row, uid) in zip(output, uids) {
            let copied = Array(row.identity.uid.utf8)
            #expect(copied == Array(uid.utf8))
        }
        let spaced = " \tloopback 48k \n"
        let blank = " \t\n"
        let layout = try makeLayout(2, rate: 48_000)
        let spacedSet = try measuredSet([capA], layout: layout, evidence: spaced)
        let blankSet = try measuredSet([capA], layout: layout, evidence: blank)
        let rows = try DeviceDescriptorProjection.descriptors(records: [
            makeRecord(6, measured: spacedSet), makeRecord(7, measured: blankSet)
        ])
        try #require(rows.count == 2)
        #expect(rows[0].binding == .measured)
        #expect(rows[0].evidence == spaced)
        #expect(rows[0].actualRate?.evidence == spaced)
        #expect(rows[1].binding == .measured)
        #expect(rows[1].evidence == blank)
        #expect(rows[1].actualRate?.evidence == blank)
    }

    // MARK: Order, limits and refusals

    @Test func deviceDescriptorProjectionKeepsInputOrder() throws {
        let recordA = try makeRecord(1)
        let recordB = try makeRecord(2)
        let recordC = try makeRecord(3)
        let first = try DeviceDescriptorProjection.descriptors(records: [recordC, recordA, recordB])
        let second = try DeviceDescriptorProjection.descriptors(records: [recordB, recordA, recordC])
        #expect(first.map(\.id) == [recordC.id, recordA.id, recordB.id])
        #expect(second.map(\.id) == [recordB.id, recordA.id, recordC.id])
    }

    @Test func deviceDescriptorProjectionAcceptsTheLimitAndRefusesOneMore() throws {
        let limit = DeviceCapabilityLimits.devices
        try #require(limit > 0)
        let over = limit + 1
        let all = Self.capPlusOne
        try #require(all.count == over)
        let below = Array(all.prefix(limit - 1))
        let atLimit = Array(all.prefix(limit))
        let fromBelow = try DeviceDescriptorProjection.descriptors(records: below)
        let fromLimit = try DeviceDescriptorProjection.descriptors(records: atLimit)
        #expect(fromBelow.map(\.id) == below.map(\.id))
        #expect(fromLimit.map(\.id) == atLimit.map(\.id))
        let tooMany = DeviceDescriptorProjectionRefusal.tooManyDevices(count: over, maximum: limit)
        #expect(throws: tooMany) {
            _ = try DeviceDescriptorProjection.descriptors(records: all)
        }
        // Both defects at once: the cap is reported first, not the repeated id.
        let repeating = try recordsEndingWithARepeat(all, count: limit)
        let distinct = Set(repeating.map(\.id))
        try #require(repeating.count == over)
        try #require(distinct.count == limit)
        #expect(throws: tooMany) {
            _ = try DeviceDescriptorProjection.descriptors(records: repeating)
        }
    }

    @Test func deviceDescriptorProjectionRefusesTheFirstRepeatedDeviceID() throws {
        let recordA = try makeRecord(1)
        let recordB = try makeRecord(2)
        let againA = try makeRecord(1, uid: "uid.again.1")
        let againB = try makeRecord(2, uid: "uid.again.2")
        let namesB = DeviceDescriptorProjectionRefusal.duplicateDeviceID(recordB.id)
        let namesA = DeviceDescriptorProjectionRefusal.duplicateDeviceID(recordA.id)
        #expect(throws: namesB) {
            _ = try DeviceDescriptorProjection.descriptors(records: [recordA, recordB, againB, againA])
        }
        #expect(throws: namesA) {
            _ = try DeviceDescriptorProjection.descriptors(records: [recordB, recordA, againA, againB])
        }
    }

    @Test func deviceDescriptorProjectionEmptyInputGivesEmptyOutput() throws {
        let fromRecords = try DeviceDescriptorProjection.descriptors(records: [])
        let fromRegistry = try DeviceDescriptorProjection.descriptors(registry: .empty)
        #expect(fromRecords.isEmpty)
        #expect(fromRegistry.isEmpty)
    }

    // MARK: Registry entry and consumers

    @Test func deviceDescriptorProjectionRegistryMatchesRecordsAndValidates() throws {
        let registry = try buildRegistry([.present, .lost, .revalidating, .mismatch, .noBaseline, .present])
        let fromRegistry = try DeviceDescriptorProjection.descriptors(registry: registry)
        let fromRecords = try DeviceDescriptorProjection.descriptors(records: registry.records)
        #expect(fromRegistry == fromRecords)
        for descriptor in fromRegistry { try descriptor.validate() }
        let measured = fromRegistry.filter { $0.binding == .measured }.count
        let reported = fromRegistry.filter { $0.binding == .reported }.count
        let present = fromRegistry.filter { $0.presence == .present }.count
        let missing = fromRegistry.filter { $0.presence == .missing }.count
        let stale = fromRegistry.filter { $0.presence == .stale }.count
        #expect(measured == 2)
        #expect(reported == 4)
        #expect(present == 2)
        #expect(missing == 1)
        #expect(stale == 3)
    }

    @Test func deviceDescriptorProjectionFeedsCapabilityDocumentAssessment() throws {
        let registry = try buildRegistry([.present, .lost])
        let projected = try DeviceDescriptorProjection.descriptors(registry: registry)
        let document = try DeviceCapabilityDocument(
            revision: .initial, host: HostID(validated: "host.x"), hostEpoch: .initial,
            devices: projected, routes: []
        )
        let requirements = [
            CapabilityRequirement(capability: capB, level: .required),
            CapabilityRequirement(capability: capC, level: .required)
        ]
        let assessment = try document.assess(requirements)
        let satisfied = assessment.requirementsSatisfied
        #expect(!satisfied)
        #expect(assessment.missingRequired == [capC])
    }

    @Test func deviceDescriptorProjectionHandlesLimitDevicesWithLimitCapabilities() throws {
        let deviceCap = DeviceCapabilityLimits.devices
        let capabilityCap = DeviceCapabilityLimits.capabilitiesPerDevice
        try #require(deviceCap > 0)
        try #require(capabilityCap > 0)
        let over = capabilityCap + 1
        let overflowing = makeCapabilityIDs(over)
        try #require(overflowing.count == over)
        let ids = Array(overflowing.prefix(capabilityCap))
        let layout = try makeLayout(2, rate: 48_000)
        let reported = try DeviceCapabilitySet.make(capabilities: ids, layout: layout)
        let baseline = try measuredSet(ids, layout: layout)
        let records = try (1...deviceCap).map { try makeRecord($0, reported: reported, measured: baseline) }
        let output = try DeviceDescriptorProjection.descriptors(records: records)
        try #require(output.count == deviceCap)
        let sampled = [output[0], output[deviceCap / 2], output[deviceCap - 1]]
        for row in sampled {
            let count = row.capabilities.count
            #expect(row.binding == .measured)
            #expect(count == capabilityCap)
        }
        let tooMany = DeviceRegistryRefusal.tooManyCapabilities(count: over, maximum: capabilityCap)
        #expect(throws: tooMany) {
            _ = try DeviceCapabilitySet.make(capabilities: overflowing)
        }
    }

    // MARK: Sources

    @Test(.enabled(if: !projectionSources().isEmpty, "the projection sources are not next to the tests"))
    func deviceDescriptorProjectionSourcesAvoidBannedTokensAndLoopCalls() {
        let texts = projectionSources()
        #expect(texts.count == 2)
        let banned = ["Ta" + "sk", "Clo" + "ck", "Da" + "te", "defa" + "ult:", "try" + "!", "static " + "var",
                      "mutat" + "ing", "Code" + "able", "FileMan" + "ager", "Dou" + "ble",
                      "contains(", "firstIndex(", "filter(", "sorted(", "first(where", "insert(at",
                      "removeFirst", "remove(at"]
        for text in texts {
            for token in banned { #expect(!text.contains(token)) }
        }
    }
}

// MARK: Fixtures

private struct FixtureFailure: Error {}

private enum ProjectionStage {
    case present
    case lost
    case revalidating
    case mismatch
    case noBaseline
}

private let capAudio = CapabilityID(validated: "cap.audio")
private let capA = CapabilityID(validated: "cap.a")
private let capB = CapabilityID(validated: "cap.b")
private let capC = CapabilityID(validated: "cap.c")
private let capD = CapabilityID(validated: "cap.d")

private func deviceID(_ index: Int) throws -> DeviceID {
    try DeviceID("dev.\(index)")
}

private func makeIdentity(_ uid: String) throws -> DeviceIdentity {
    try DeviceIdentity(DeviceIdentityFields(uid: uid, evidence: [.deviceUID]))
}

private func makeLayout(_ channels: Int, rate: Int) throws -> ChannelLayout {
    try ChannelLayout(inputs: channels, outputs: channels, sampleRate: rate)
}

private func makeRate(_ evidence: String) throws -> MeasuredRate {
    try MeasuredRate(MeasuredRateFields(hertz: 48_000, evidence: evidence))
}

// A nil evidence builds a baseline without an actual rate.
private func measuredSet(
    _ caps: [CapabilityID], layout: ChannelLayout?, evidence: String? = "readback.48k", bufferFrames: Int = 128
) throws -> DeviceCapabilitySet {
    let rate = try evidence.map { try makeRate($0) }
    return try DeviceCapabilitySet.make(
        capabilities: caps, layout: layout, actualRate: rate, bufferFrames: bufferFrames
    )
}

private func stageReported() throws -> DeviceCapabilitySet {
    try DeviceCapabilitySet.make(capabilities: [capC, capA], layout: makeLayout(2, rate: 44_100))
}

private func stageBaseline(bufferFrames: Int = 128) throws -> DeviceCapabilitySet {
    try measuredSet([capB, capA, capD], layout: makeLayout(8, rate: 48_000), bufferFrames: bufferFrames)
}

private func makeRecord(
    _ index: Int, kind: DeviceKind = .audioInterface, uid: String? = nil,
    reported: DeviceCapabilitySet? = nil, measured: DeviceCapabilitySet? = nil
) throws -> DeviceRecord {
    try DeviceRecord.make(
        id: deviceID(index),
        kind: kind,
        identity: DeviceIdentityFields(uid: uid ?? "uid.\(index)", evidence: [.deviceUID]),
        reportedCapabilities: reported ?? stageReported(),
        measuredCapabilities: measured
    )
}

// dev.1 to dev.<count>; a record that fails to build shows up as a short array, so callers require the count.
private func makeRecords(_ count: Int) -> [DeviceRecord] {
    guard count > 0 else { return [] }
    return (1...count).compactMap { try? makeRecord($0) }
}

// The first `count` records of `base`, then a second record with the id of the first, so the array repeats an id.
private func recordsEndingWithARepeat(_ base: [DeviceRecord], count: Int) throws -> [DeviceRecord] {
    guard let first = base.first else { throw FixtureFailure() }
    var records = [DeviceRecord](base.prefix(count))
    records.append(first)
    return records
}

// cap.1 to cap.<count>, with the same short-array rule as makeRecords.
private func makeCapabilityIDs(_ count: Int) -> [CapabilityID] {
    guard count > 0 else { return [] }
    return (1...count).compactMap { try? CapabilityID("cap.\($0)") }
}

// The golden of every reported row: the reported fixture data, no evidence and no rate.
private func reportedGolden(_ index: Int, presence: DevicePresence) throws -> DeviceDescriptor {
    try DeviceDescriptor(
        id: deviceID(index), kind: .audioInterface, layout: makeLayout(2, rate: 44_100), binding: .reported,
        identity: makeIdentity("uid.\(index)"), presence: presence, evidence: nil, capabilities: [capA, capC]
    )
}

private func applyEvent(_ registry: DeviceRegistry, _ event: DeviceRegistryEvent) throws -> DeviceRegistry {
    guard case .accepted(let next, _) = registry.applying(event) else { throw FixtureFailure() }
    return next
}

private func buildRegistry(_ stages: [ProjectionStage]) throws -> DeviceRegistry {
    var registry = DeviceRegistry.empty
    for (offset, stage) in stages.enumerated() {
        registry = try adding(stage, index: offset + 1, to: registry)
    }
    return registry
}

private func singleRecord(_ stage: ProjectionStage) throws -> DeviceRecord {
    guard let record = try buildRegistry([stage]).records.first else { throw FixtureFailure() }
    return record
}

// Every non-present state goes through the reducer, so no record is faked.
private func adding(_ stage: ProjectionStage, index: Int, to registry: DeviceRegistry) throws -> DeviceRegistry {
    let baseline = try stageBaseline()
    switch stage {
    case .present:
        return try applyEvent(registry, .observed(makeRecord(index, measured: baseline)))
    case .lost:
        let record = try makeRecord(index, measured: baseline)
        let observed = try applyEvent(registry, .observed(record))
        return try applyEvent(observed, .disappeared(record.identityKey))
    case .revalidating:
        return try reachRevalidating(index, baseline: baseline, in: registry).registry
    case .mismatch:
        let next = try reachRevalidating(index, baseline: baseline, in: registry)
        let changed = try stageBaseline(bufferFrames: 256)
        return try applyEvent(next.registry, .capabilitiesMeasured(next.key, changed))
    case .noBaseline:
        let next = try reachRevalidating(index, baseline: nil, in: registry)
        return try applyEvent(next.registry, .capabilitiesMeasured(next.key, baseline))
    }
}

private func reachRevalidating(
    _ index: Int, baseline: DeviceCapabilitySet?, in registry: DeviceRegistry
) throws -> (registry: DeviceRegistry, key: DeviceIdentityKey) {
    let record = try makeRecord(index, measured: baseline)
    let observed = try applyEvent(registry, .observed(record))
    let lost = try applyEvent(observed, .disappeared(record.identityKey))
    return (try applyEvent(lost, .returned(record.identityKey)), record.identityKey)
}

private func projectionSources() -> [String] {
    let names = ["DeviceDescriptorProjection.swift", "DeviceDescriptorProjectionRefusal.swift"]
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let relative = "Shared/Audio/Devices/Registry/Descriptors/"
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
