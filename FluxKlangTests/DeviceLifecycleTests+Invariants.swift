import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension DeviceLifecycleTests {
    @Test func duplicateObservationMayOmitMeasurement() throws {
        let baseline = try Self.registryTestMeasured()
        let original = try Self.registryTestRecord(1, measured: baseline)
        let registry = try #require(Self.registryTestReduce(.empty, .observed(original)))
        let noInformation = try Self.registryTestRecord(1)
        let changedBaseline = try Self.registryTestRecord(
            1, measured: Self.registryTestMeasured(bufferFrames: 256)
        )

        #expect(registry.applying(.observed(noInformation))
            == .accepted(registry, effect: nil))
        #expect(registry.applying(.observed(changedBaseline))
            == .refused(.conflictingObservation(original.identityKey)))
    }

    @Test func missingBaselineStaysNilOnRepeat() throws {
        let record = try Self.registryTestRecord(1)
        let registered = try #require(Self.registryTestReduce(.empty, .observed(record)))
        let lost = try #require(Self.registryTestReduce(
            registered, .disappeared(record.identityKey)
        ))
        let returning = try #require(Self.registryTestReduce(
            lost, .returned(record.identityKey)
        ))
        let measurement = try Self.registryTestMeasured()
        let firstResult = returning.applying(
            .capabilitiesMeasured(record.identityKey, measurement)
        )
        guard case .accepted(let first, let firstEffect) = firstResult else {
            Issue.record("first returned measurement was refused")
            return
        }
        let firstRecord = try #require(first.record(for: record.identityKey))
        #expect(firstRecord.lifecycle == .muted(.noMeasuredBaseline))
        #expect(firstRecord.measuredCapabilities == nil)

        let secondResult = first.applying(
            .capabilitiesMeasured(record.identityKey, measurement)
        )
        guard case .accepted(let second, let secondEffect) = secondResult else {
            Issue.record("repeated returned measurement was refused")
            return
        }
        #expect(firstEffect == .lifecycleChanged(
            record.id, from: .revalidating, to: .muted(.noMeasuredBaseline)
        ))
        #expect(secondEffect == nil)
        let secondRecord = try #require(second.record(for: record.identityKey))
        #expect(secondRecord.lifecycle == .muted(.noMeasuredBaseline))
        #expect(secondRecord.measuredCapabilities == nil)
    }

    @Test func presentMismatchMutesImmediately() throws {
        let baseline = try Self.registryTestMeasured()
        let record = try Self.registryTestRecord(1, measured: baseline)
        let registry = try #require(Self.registryTestReduce(.empty, .observed(record)))
        let mismatch = try Self.registryTestMeasured(bufferFrames: 256)
        let result = registry.applying(
            .capabilitiesMeasured(record.identityKey, mismatch)
        )
        guard case .accepted(let muted, let effect) = result else {
            Issue.record("present mismatch measurement was refused")
            return
        }
        #expect(effect == .lifecycleChanged(
            record.id, from: .present, to: .muted(.capabilityMismatch(.bufferFrames))
        ))
        let mutedRecord = try #require(muted.record(for: record.identityKey))
        #expect(mutedRecord.lifecycle == .muted(.capabilityMismatch(.bufferFrames)))
        #expect(!muted.allowsEngineAcquisition)
    }

    @Test func registryEqualityDistinguishesLifecycle() throws {
        let record = try Self.registryTestRecord(20)
        let present = try Self.registryForEquality(record)
        let lost = try #require(Self.registryTestReduce(
            present, .disappeared(record.identityKey)
        ))

        #expect(present != lost)
    }

    @Test func registryEqualityPinsRecordFields() throws {
        let id = try DeviceID("dev.registry-equality")
        let uid = "uid.registry-equality"
        let baseline = try Self.registryTestMeasured()
        let original = try Self.registryTestRecord(id: id, uid: uid, measured: baseline)
        let originalRegistry = try Self.registryForEquality(original)
        let changedBaseline = try Self.registryTestRecord(
            id: id, uid: uid, measured: Self.registryTestMeasured(bufferFrames: 256)
        )
        let baselineRegistry = try Self.registryForEquality(changedBaseline)
        let modelEvidence = try Self.registryTestRecord(
            id: id, uid: uid, evidence: [.deviceUID, .modelUID], measured: baseline
        )
        let modelRegistry = try Self.registryForEquality(modelEvidence)
        let otherID = try DeviceID("dev.registry-equality.other")
        let changedID = try Self.registryTestRecord(
            id: otherID, uid: uid, measured: baseline
        )
        let deviceIDRegistry = try Self.registryForEquality(changedID)

        #expect(originalRegistry != baselineRegistry)
        #expect(originalRegistry != modelRegistry)
        #expect(originalRegistry != deviceIDRegistry)
    }

    @Test func registryEqualityAndHashAreOrderStable() throws {
        var forward = DeviceRegistry.empty
        for index in 0..<64 {
            let record = try Self.registryTestRecord(100 + index)
            forward = try #require(Self.registryTestReduce(forward, .observed(record)))
        }
        var reverse = DeviceRegistry.empty
        for index in (0..<64).reversed() {
            let record = try Self.registryTestRecord(100 + index)
            reverse = try #require(Self.registryTestReduce(reverse, .observed(record)))
        }

        #expect(forward == reverse)
        var forwardHasher = Hasher()
        forwardHasher.combine(forward)
        let forwardHash = forwardHasher.finalize()
        var reverseHasher = Hasher()
        reverseHasher.combine(reverse)
        let reverseHash = reverseHasher.finalize()
        #expect(forwardHash == reverseHash)
    }

    private static func registryForEquality(_ record: DeviceRecord) throws -> DeviceRegistry {
        try #require(Self.registryTestReduce(.empty, .observed(record)))
    }
}
