import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct DeviceLifecycleTests {
    private static let audioCapability = CapabilityID(validated: "cap.audio")
    private static let midiCapability = CapabilityID(validated: "cap.midi")
    private static let mainRole = RoleID(validated: "role.main")

    @Test func uidEvidenceIsIdentityAndModelOnlyIsRefused() throws {
        let reported = try DeviceCapabilitySet.make(capabilities: [Self.audioCapability])
        let first = try Self.record(1, identityEvidence: [.deviceUID], reported: reported)
        let enriched = try Self.record(1, identityEvidence: [.deviceUID, .modelUID], reported: reported)
        let endpoint = try Self.record(1, identityEvidence: [.endpointUID], reported: reported)
        #expect(first.identityKey == enriched.identityKey)
        #expect(first.identityKey != endpoint.identityKey)
        #expect(throws: DeviceRegistryRefusal.missingUIDEvidence) {
            return try DeviceRecord.make(
                id: DeviceID(validated: "dev.model-only"), kind: .audioInterface,
                identity: DeviceIdentityFields(uid: "model.uid", evidence: [.modelUID]),
                reportedCapabilities: reported
            )
        }
    }

    @Test func duplicateUIDObservationIsIdempotentWithoutChangingLoss() throws {
        let record = try Self.record(1, measured: Self.measuredSet())
        guard var registry = Self.registered(record) else { Issue.record("record was refused"); return }
        guard let lost = Self.reduce(registry, .disappeared(record.identityKey)) else {
            Issue.record("disappearance was refused")
            return
        }
        registry = lost
        let result = registry.applying(.observed(record))
        #expect(result == .accepted(registry, effect: nil))
    }

    @Test func presentLostRevalidatingAndMeasuredMatch() throws {
        let measured = try Self.measuredSet()
        let record = try Self.record(1, measured: measured)
        guard var registry = Self.registered(record) else { Issue.record("record was refused"); return }
        #expect(registry.allowsEngineAcquisition)

        guard let lost = Self.reduce(registry, .disappeared(record.identityKey)) else {
            Issue.record("disappearance was refused")
            return
        }
        registry = lost
        #expect(registry.records.first?.lifecycle == .lostMuted)
        #expect(!registry.allowsEngineAcquisition)

        guard let returning = Self.reduce(registry, .returned(record.identityKey)) else {
            Issue.record("return was refused")
            return
        }
        registry = returning
        #expect(registry.records.first?.lifecycle == .revalidating)
        #expect(!registry.allowsEngineAcquisition)

        guard let restored = Self.reduce(
            registry, .capabilitiesMeasured(record.identityKey, measured)
        ) else {
            Issue.record("matching measurement was refused")
            return
        }
        #expect(restored.records.first?.lifecycle == .present)
        #expect(restored.allowsEngineAcquisition)
    }

    @Test func everyMeasuredFieldMismatchStaysMutedUntilExplicitMatch() throws {
        let baseline = try Self.measuredSet()
        let differentCapabilities = try DeviceCapabilitySet.make(
            capabilities: [Self.midiCapability], layout: baseline.layout,
            actualRate: baseline.actualRate, bufferFrames: baseline.bufferFrames
        )
        let differentLayout = try DeviceCapabilitySet.make(
            capabilities: baseline.capabilities,
            layout: ChannelLayout(inputs: 4, outputs: 2, sampleRate: 48_000),
            actualRate: baseline.actualRate, bufferFrames: baseline.bufferFrames
        )
        let differentRate = try DeviceCapabilitySet.make(
            capabilities: baseline.capabilities, layout: baseline.layout,
            actualRate: Self.rate(44_100, evidence: "readback.44k"), bufferFrames: baseline.bufferFrames
        )
        let differentBuffer = try DeviceCapabilitySet.make(
            capabilities: baseline.capabilities, layout: baseline.layout,
            actualRate: baseline.actualRate, bufferFrames: 256
        )
        let cases: [(DeviceCapabilitySet, DeviceCapabilityField)] = [
            (differentCapabilities, .capabilities), (differentLayout, .layout),
            (differentRate, .actualRate), (differentBuffer, .bufferFrames)
        ]

        for (index, mismatch) in cases.enumerated() {
            let record = try Self.record(index + 1, measured: baseline)
            guard let registry = Self.registered(record) else {
                Issue.record("record \(index) was refused")
                return
            }
            guard let lost = Self.reduce(registry, .disappeared(record.identityKey)),
                  let returning = Self.reduce(lost, .returned(record.identityKey)),
                  let muted = Self.reduce(
                    returning, .capabilitiesMeasured(record.identityKey, mismatch.0)
                  ) else {
                Issue.record("transition \(index) was refused")
                return
            }
            #expect(muted.records.first?.lifecycle == .muted(.capabilityMismatch(mismatch.1)))
            #expect(!muted.allowsEngineAcquisition)
            guard let restored = Self.reduce(
                muted, .capabilitiesMeasured(record.identityKey, baseline)
            ) else {
                Issue.record("matching measurement \(index) was refused")
                return
            }
            #expect(restored.records.first?.lifecycle == .present)
        }
    }

    @Test func reportedValuesDoNotReplaceMeasuredBaseline() throws {
        let measured = try Self.measuredSet()
        let reported = try DeviceCapabilitySet.make(capabilities: [Self.midiCapability])
        let record = try Self.record(1, reported: reported, measured: measured)
        guard let registry = Self.registered(record) else { Issue.record("record was refused"); return }
        #expect(registry.records.first?.reportedCapabilities == reported)
        #expect(registry.records.first?.measuredCapabilities == measured)

        guard let lost = Self.reduce(registry, .disappeared(record.identityKey)),
              let returning = Self.reduce(lost, .returned(record.identityKey)),
              let restored = Self.reduce(
                returning, .capabilitiesMeasured(record.identityKey, measured)
              ) else {
            Issue.record("matching measured values did not restore the record")
            return
        }
        #expect(restored.records.first?.reportedCapabilities == reported)
        #expect(restored.records.first?.measuredCapabilities == measured)
    }

    @Test func firstMeasurementEstablishesBaselineWithoutChangingPresence() throws {
        let record = try Self.record(1)
        let measured = try Self.measuredSet()
        guard let registry = Self.registered(record),
              let measuredRegistry = Self.reduce(
                registry, .capabilitiesMeasured(record.identityKey, measured)
              ) else {
            Issue.record("initial measurement was refused")
            return
        }
        #expect(measuredRegistry.records.first?.lifecycle == .present)
        #expect(measuredRegistry.records.first?.measuredCapabilities == measured)
        #expect(measuredRegistry.allowsEngineAcquisition)
    }

    @Test func missingBaselineCannotBeInventedOnReturnButExplicitReplacementCan() throws {
        let record = try Self.record(1)
        guard let registry = Self.registered(record),
              let lost = Self.reduce(registry, .disappeared(record.identityKey)),
              let returning = Self.reduce(lost, .returned(record.identityKey)),
              let muted = Self.reduce(
                returning, .capabilitiesMeasured(record.identityKey, try Self.measuredSet())
              ) else {
            Issue.record("record transition was refused")
            return
        }
        #expect(muted.records.first?.lifecycle == .muted(.noMeasuredBaseline))
        #expect(!muted.allowsEngineAcquisition)

        let replacement = try Self.record(1, measured: Self.measuredSet())
        guard let replaced = Self.reduce(muted, .replacingRecord(replacement)) else {
            Issue.record("explicit replacement was refused")
            return
        }
        #expect(replaced.records.first?.lifecycle == .present)
        #expect(replaced.allowsEngineAcquisition)
    }

    @Test func globalAcquisitionGuardBlocksEveryWindowForAnyUnavailableRecord() throws {
        let one = try Self.record(1, measured: Self.measuredSet())
        let two = try Self.record(2, measured: Self.measuredSet())
        guard let first = Self.registered(one),
              let both = Self.reduce(first, .observed(two)),
              let lost = Self.reduce(both, .disappeared(two.identityKey)) else {
            Issue.record("setup was refused")
            return
        }
        #expect(!lost.allowsEngineAcquisition)
        guard let returning = Self.reduce(lost, .returned(two.identityKey)) else {
            Issue.record("return was refused")
            return
        }
        #expect(!returning.allowsEngineAcquisition)
        guard let restored = Self.reduce(
            returning, .capabilitiesMeasured(two.identityKey, try Self.measuredSet())
        ) else {
            Issue.record("matching measurement was refused")
            return
        }
        #expect(restored.allowsEngineAcquisition)
    }

    @Test func deviceAndCapabilityLimitsAcceptNAndRefuseNPlusOne() throws {
        let limit = DeviceCapabilityLimits.devices
        var registry = DeviceRegistry.empty
        var firstKey: DeviceIdentityKey?
        for index in 0..<limit {
            let record = try Self.record(index)
            if index == 0 { firstKey = record.identityKey }
            guard let next = Self.reduce(registry, .observed(record)) else {
                Issue.record("device N=\(limit) was refused at \(index)")
                return
            }
            registry = next
        }
        #expect(registry.records.count == limit)
        guard let firstKey, let lost = Self.reduce(registry, .disappeared(firstKey)) else {
            Issue.record("the first record could not be marked Lost")
            return
        }
        registry = lost
        let beyond = try Self.record(limit)
        #expect(registry.applying(.observed(beyond))
            == .refused(.tooManyDevices(count: limit + 1, maximum: limit)))
        #expect(registry.records.count == limit)
        #expect(registry.record(for: firstKey)?.lifecycle == .lostMuted)

        let capabilityLimit = DeviceCapabilityLimits.capabilitiesPerDevice
        let capabilities = try (0...capabilityLimit).map {
            try CapabilityID("cap.item.\($0)")
        }
        let atLimit = try DeviceCapabilitySet.make(capabilities: Array(capabilities.prefix(capabilityLimit)))
        #expect(atLimit.capabilities.count == capabilityLimit)
        #expect(throws: DeviceRegistryRefusal.tooManyCapabilities(
            count: capabilityLimit + 1, maximum: capabilityLimit
        )) {
            try DeviceCapabilitySet.make(capabilities: capabilities)
        }
    }

    @Test func capabilitySetRefusalsAreTypedAndCanonical() throws {
        let first = CapabilityID(validated: "cap.alpha")
        let second = CapabilityID(validated: "cap.beta")
        let input = [second, first]
        let set = try DeviceCapabilitySet.make(capabilities: input)
        #expect(set.capabilities == [first, second])
        #expect(throws: DeviceRegistryRefusal.duplicateCapability(first)) {
            try DeviceCapabilitySet.make(capabilities: [first, first])
        }
        #expect(throws: DeviceRegistryRefusal.invalidBufferFrames(0)) {
            try DeviceCapabilitySet.make(capabilities: [], bufferFrames: 0)
        }
        #expect(try DeviceCapabilitySet.make(capabilities: [], bufferFrames: 1).bufferFrames == 1)
        let reportedWithMeasurement = try DeviceCapabilitySet.make(
            capabilities: [], actualRate: Self.rate(48_000, evidence: "readback")
        )
        #expect(throws: DeviceRegistryRefusal.measurementInReportedCapabilities) {
            try DeviceRecord.make(
                id: DeviceID(validated: "dev.bad-report"), kind: .audioInterface,
                identity: DeviceIdentityFields(uid: "uid.bad-report", evidence: [.deviceUID]),
                reportedCapabilities: reportedWithMeasurement
            )
        }
    }

    @Test func allEventRefusalsLeaveTheInputRegistryUnchanged() throws {
        let record = try Self.record(1, measured: Self.measuredSet())
        guard let original = Self.registered(record) else { Issue.record("record was refused"); return }
        let unknown = try Self.record(2).identityKey
        let changedObservation = try Self.record(1, reported: DeviceCapabilitySet.make(
            capabilities: [Self.midiCapability]
        ))
        let duplicateID = try Self.record(2, id: record.id)
        let replacementForUnknown = try Self.record(2)
        let rejected: [(DeviceRegistryEvent, DeviceRegistryRefusal)] = [
            (.disappeared(unknown), .unknownDevice(unknown)),
            (.returned(unknown), .unknownDevice(unknown)),
            (.capabilitiesMeasured(unknown, try Self.measuredSet()), .unknownDevice(unknown)),
            (.observed(changedObservation), .conflictingObservation(record.identityKey)),
            (.observed(duplicateID), .duplicateDeviceID(record.id)),
            (.replacingRecord(replacementForUnknown), .unknownDevice(replacementForUnknown.identityKey))
        ]
        for (event, refusal) in rejected {
            #expect(original.applying(event) == .refused(refusal))
        }

        guard let lost = Self.reduce(original, .disappeared(record.identityKey)) else {
            Issue.record("disappearance was refused")
            return
        }
        #expect(lost.applying(.capabilitiesMeasured(record.identityKey, try Self.measuredSet()))
            == .refused(.deviceNotAvailable(record.identityKey)))
    }

    @Test func lossReportContainsAffectedRecordsRoutesReasonsAndStableOrder() throws {
        let zRecord = try Self.record(1, uid: "uid.z", measured: Self.measuredSet())
        let aRecord = try Self.record(2, uid: "uid.a", measured: Self.measuredSet())
        guard let registry = Self.registered(zRecord),
              let withA = Self.reduce(registry, .observed(aRecord)),
              let lost = Self.reduce(withA, .disappeared(zRecord.identityKey)),
              let returning = Self.reduce(lost, .returned(zRecord.identityKey)),
              let muted = Self.reduce(
                returning,
                .capabilitiesMeasured(zRecord.identityKey, try Self.measuredSet(
                    bufferFrames: 256
                ))
              ) else {
            Issue.record("loss setup was refused")
            return
        }
        let routes = [
            try Self.route("route.z", device: zRecord.id),
            try Self.route("route.a", device: zRecord.id),
            try Self.route("route.other", device: aRecord.id)
        ]
        let report = try muted.lossReport(routes: routes)
        #expect(report.entries.map(\.device) == [zRecord.id])
        let reportEntry = try #require(report.entries.first)
        #expect(reportEntry.reason == .muted(.capabilityMismatch(.bufferFrames)))
        #expect(reportEntry.routes == [
            RouteID(validated: "route.a"), RouteID(validated: "route.z")
        ])
        #expect(report.affectedRoutes == reportEntry.routes)

        let secondLost = try #require(Self.reduce(muted, .disappeared(aRecord.identityKey)))
        let ordered = try secondLost.lossReport(routes: routes)
        #expect(ordered.entries.map(\.identity) == [aRecord.identityKey, zRecord.identityKey])
        let orderedFirst = try #require(ordered.entries.first)
        let orderedSecond = try #require(ordered.entries.dropFirst().first)
        #expect(orderedFirst.reason == .lost)
        #expect(orderedSecond.reason == .muted(.capabilityMismatch(.bufferFrames)))
    }

    @Test func lossReportRefusesRouteNPlusOneAndDuplicateIDs() throws {
        let record = try Self.record(1, measured: Self.measuredSet())
        guard let registry = Self.registered(record),
              let lost = Self.reduce(registry, .disappeared(record.identityKey)) else {
            Issue.record("loss setup was refused")
            return
        }
        let limit = DeviceCapabilityLimits.routes
        let atLimit = try (0..<limit).map { index in
            try Self.route("route.\(index)", device: record.id)
        }
        let atLimitReport = try lost.lossReport(routes: atLimit)
        let atLimitEntry = try #require(atLimitReport.entries.first)
        #expect(atLimitEntry.routes.count == limit)
        let tooMany = try (0...limit).map { index in
            try Self.route("route.\(index)", device: record.id)
        }
        #expect(throws: DeviceRegistryRefusal.tooManyRoutes(count: limit + 1, maximum: limit)) {
            try lost.lossReport(routes: tooMany)
        }
        #expect(throws: DeviceRegistryRefusal.duplicateRoute(RouteID(validated: "route.dup"))) {
            try lost.lossReport(routes: [
                try Self.route("route.dup", device: record.id),
                try Self.route("route.dup", device: record.id)
            ])
        }
    }

    @Test func permutedDistinctObservationsProduceTheSameSortedRegistry() throws {
        let records = try [
            Self.record(1, uid: "uid.c"), Self.record(2, uid: "uid.a"), Self.record(3, uid: "uid.b")
        ]
        var forward = DeviceRegistry.empty
        for record in records {
            guard let next = Self.reduce(forward, .observed(record)) else {
                Issue.record("forward observation was refused")
                return
            }
            forward = next
        }
        var reverse = DeviceRegistry.empty
        for record in records.reversed() {
            guard let next = Self.reduce(reverse, .observed(record)) else {
                Issue.record("reverse observation was refused")
                return
            }
            reverse = next
        }
        #expect(forward == reverse)
        #expect(forward.records.map(\.identityKey.uid) == ["uid.a", "uid.b", "uid.c"])
    }

    private static func record(
        _ index: Int, uid: String? = nil, identityEvidence: Set<IdentityEvidence> = [.deviceUID],
        reported: DeviceCapabilitySet? = nil, measured: DeviceCapabilitySet? = nil, id: DeviceID? = nil
    ) throws -> DeviceRecord {
        let deviceID = try id ?? DeviceID("dev.\(index)")
        let reportedSet = try reported ?? DeviceCapabilitySet.make(capabilities: [Self.audioCapability])
        return try DeviceRecord.make(
            id: deviceID,
            kind: .audioInterface,
            identity: DeviceIdentityFields(uid: uid ?? "uid.\(index)", evidence: identityEvidence),
            reportedCapabilities: reportedSet,
            measuredCapabilities: measured
        )
    }

    private static func measuredSet(bufferFrames: Int = 128) throws -> DeviceCapabilitySet {
        try DeviceCapabilitySet.make(
            capabilities: [Self.audioCapability],
            layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000),
            actualRate: Self.rate(48_000, evidence: "readback.48k"),
            bufferFrames: bufferFrames
        )
    }

    private static func rate(_ hertz: Double, evidence: String) throws -> MeasuredRate {
        try MeasuredRate(MeasuredRateFields(hertz: hertz, evidence: evidence))
    }

    private static func route(_ id: String, device: DeviceID) throws -> AudioRoute {
        AudioRoute(
            id: try RouteID(id), role: Self.mainRole, device: device,
            direction: .output, channels: [0, 1], binding: .confirmed
        )
    }

    private static func registered(_ record: DeviceRecord) -> DeviceRegistry? {
        reduce(.empty, .observed(record))
    }

    private static func reduce(_ registry: DeviceRegistry, _ event: DeviceRegistryEvent) -> DeviceRegistry? {
        guard case .accepted(let next, _) = registry.applying(event) else { return nil }
        return next
    }
}
