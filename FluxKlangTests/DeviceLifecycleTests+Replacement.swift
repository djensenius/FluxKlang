import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension DeviceLifecycleTests {
    static let registryTestAudio = CapabilityID(validated: "cap.registry-test.audio")

    static func registryTestRecord(
        _ index: Int, uid: String? = nil, measured: DeviceCapabilitySet? = nil
    ) throws -> DeviceRecord {
        try registryTestRecord(
            id: DeviceID("dev.registry-test.\(index)"),
            uid: uid ?? "uid.registry-test.\(index)",
            measured: measured
        )
    }

    static func registryTestRecord(
        id: DeviceID, uid: String, evidence: Set<IdentityEvidence> = [.deviceUID],
        measured: DeviceCapabilitySet? = nil
    ) throws -> DeviceRecord {
        let reported = try DeviceCapabilitySet.make(capabilities: [Self.registryTestAudio])
        return try DeviceRecord.make(
            id: id,
            kind: .audioInterface,
            identity: DeviceIdentityFields(uid: uid, evidence: evidence),
            reportedCapabilities: reported,
            measuredCapabilities: measured
        )
    }

    static func registryTestMeasured(
        bufferFrames: Int = 128, evidence: String = "fixture.readback"
    ) throws -> DeviceCapabilitySet {
        try DeviceCapabilitySet.make(
            capabilities: [Self.registryTestAudio],
            layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000),
            actualRate: try MeasuredRate(
                MeasuredRateFields(hertz: 48_000, evidence: evidence)
            ),
            bufferFrames: bufferFrames
        )
    }

    static func registryTestReduce(
        _ registry: DeviceRegistry, _ event: DeviceRegistryEvent
    ) -> DeviceRegistry? {
        guard case .accepted(let updated, _) = registry.applying(event) else { return nil }
        return updated
    }

    @Test func lostReplacementIsRefused() throws {
        let record = try Self.registryTestRecord(1, measured: Self.registryTestMeasured())
        let registered = try #require(Self.registryTestReduce(.empty, .observed(record)))
        let lost = try #require(Self.registryTestReduce(
            registered, .disappeared(record.identityKey)
        ))

        #expect(lost.applying(.replacingRecord(record))
            == .refused(.deviceNotAvailable(record.identityKey)))
        #expect(!lost.allowsEngineAcquisition)
    }

    @Test func replacementKeepsUIDDeviceID() throws {
        let original = try Self.registryTestRecord(1, uid: "uid.fixed")
        let registry = try #require(Self.registryTestReduce(.empty, .observed(original)))
        let replacement = try Self.registryTestRecord(
            id: DeviceID(validated: "dev.changed"), uid: "uid.fixed"
        )

        #expect(registry.applying(.replacingRecord(replacement))
            == .refused(.conflictingReplacement(original.identityKey)))
    }

    @Test func replacementRejectsOtherIdentityDeviceID() throws {
        let idA = try DeviceID("dev.registry-test.a")
        let idB = try DeviceID("dev.registry-test.b")
        let recordA = try Self.registryTestRecord(id: idA, uid: "uid.registry-test.a")
        let recordB = try Self.registryTestRecord(id: idB, uid: "uid.registry-test.b")
        let registeredA = try #require(Self.registryTestReduce(.empty, .observed(recordA)))
        let withBoth = try #require(Self.registryTestReduce(registeredA, .observed(recordB)))
        var currentRegistry = withBoth
        let registryBeforeCollision = currentRegistry
        let collision = try Self.registryTestRecord(id: idB, uid: "uid.registry-test.a")
        let collisionResult = currentRegistry.applying(.replacingRecord(collision))
        if case .accepted(let updated, _) = collisionResult { currentRegistry = updated }

        #expect(collisionResult == .refused(.conflictingReplacement(recordA.identityKey)))
        #expect(currentRegistry == registryBeforeCollision)

        // Keep A's bound ID; it remains unique in the registry and proves valid replacement is allowed.
        let usableReplacement = try Self.registryTestRecord(
            id: idA, uid: "uid.registry-test.a", measured: Self.registryTestMeasured()
        )
        guard case .accepted(let updated, let effect) =
                currentRegistry.applying(.replacingRecord(usableReplacement)) else {
            Issue.record("non-colliding replacement using A's bound DeviceID was refused")
            return
        }
        #expect(effect == .replaced(idA))
        #expect(updated.record(for: recordA.identityKey) == usableReplacement)
        #expect(updated.record(for: recordB.identityKey) == recordB)
    }

    @Test func identicalReplacementHasNoEffect() throws {
        let record = try Self.registryTestRecord(1, measured: Self.registryTestMeasured())
        let registry = try #require(Self.registryTestReduce(.empty, .observed(record)))

        #expect(registry.applying(.replacingRecord(record)) == .accepted(registry, effect: nil))
    }

    @Test func replacementAllowedInActiveStates() throws {
        let presentRecord = try Self.registryTestRecord(1)
        let presentRegistry = try #require(Self.registryTestReduce(.empty, .observed(presentRecord)))
        let presentBaseline = try Self.registryTestMeasured(bufferFrames: 256)
        let presentReplacement = try Self.registryTestRecord(
            1, uid: "uid.registry-test.1", measured: presentBaseline
        )
        guard case .accepted(let replacedPresent, let presentEffect) =
                presentRegistry.applying(.replacingRecord(presentReplacement)) else {
            Issue.record("present replacement was refused")
            return
        }
        #expect(presentEffect == .replaced(presentRecord.id))
        #expect(replacedPresent.records.first?.measuredCapabilities == presentBaseline)

        let baseline = try Self.registryTestMeasured()
        let returningRecord = try Self.registryTestRecord(2, measured: baseline)
        let registered = try #require(Self.registryTestReduce(.empty, .observed(returningRecord)))
        let lost = try #require(Self.registryTestReduce(
            registered, .disappeared(returningRecord.identityKey)
        ))
        let revalidating = try #require(Self.registryTestReduce(
            lost, .returned(returningRecord.identityKey)
        ))
        let newBaseline = try Self.registryTestMeasured(bufferFrames: 256)
        let revalidatingReplacement = try Self.registryTestRecord(
            2, uid: "uid.registry-test.2", measured: newBaseline
        )
        guard case .accepted(let replacedRevalidating, let revalidatingEffect) =
                revalidating.applying(.replacingRecord(revalidatingReplacement)) else {
            Issue.record("revalidating replacement was refused")
            return
        }
        #expect(revalidatingEffect == .replaced(returningRecord.id))
        #expect(replacedRevalidating.records.first?.lifecycle == .present)

        let mutedRecord = try Self.registryTestRecord(3, measured: baseline)
        let mutedRegistry = try #require(Self.registryTestReduce(.empty, .observed(mutedRecord)))
        let mutedLost = try #require(Self.registryTestReduce(
            mutedRegistry, .disappeared(mutedRecord.identityKey)
        ))
        let mutedReturning = try #require(Self.registryTestReduce(
            mutedLost, .returned(mutedRecord.identityKey)
        ))
        let mismatch = try Self.registryTestMeasured(bufferFrames: 256)
        let muted = try #require(Self.registryTestReduce(
            mutedReturning, .capabilitiesMeasured(mutedRecord.identityKey, mismatch)
        ))
        let mutedReplacement = try Self.registryTestRecord(
            3, uid: "uid.registry-test.3", measured: mismatch
        )
        guard case .accepted(let replacedMuted, let mutedEffect) =
                muted.applying(.replacingRecord(mutedReplacement)) else {
            Issue.record("muted mismatch replacement was refused")
            return
        }
        #expect(mutedEffect == .replaced(mutedRecord.id))
        #expect(replacedMuted.records.first?.lifecycle == .present)
    }
}
