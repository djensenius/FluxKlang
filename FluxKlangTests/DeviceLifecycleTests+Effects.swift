import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private enum RegistryEffectExpectation {
    case accepted(DeviceRegistryEffect?)
    case refused(DeviceRegistryRefusal)
}

private struct RegistryEffectCase {
    let name: String
    let registry: DeviceRegistry
    let event: DeviceRegistryEvent
    let expected: RegistryEffectExpectation
    let expectedRegistry: DeviceRegistry?
}

extension DeviceLifecycleTests {
    @Test func reducerEffectsMatchTransitionTable() throws {
        for scenario in try Self.registryEffectCases() {
            let result = scenario.registry.applying(scenario.event)
            switch scenario.expected {
            case .accepted(let expectedEffect):
                guard case .accepted(_, let actualEffect) = result else {
                    Issue.record("\(scenario.name): expected acceptance")
                    continue
                }
                #expect(actualEffect == expectedEffect)
                if let expectedRegistry = scenario.expectedRegistry {
                    #expect(result == .accepted(expectedRegistry, effect: expectedEffect))
                }
            case .refused(let refusal):
                #expect(result == .refused(refusal))
            }
        }
    }

    private static func registryEffectCases() throws -> [RegistryEffectCase] {
        try lifecycleEffectCases() + measurementEffectCases() + replacementEffectCases()
    }

    private static func lifecycleEffectCases() throws -> [RegistryEffectCase] {
        let record = try Self.registryTestRecord(1, measured: Self.registryTestMeasured())
        let empty = DeviceRegistry.empty
        let registered = try #require(Self.registryTestReduce(.empty, .observed(record)))
        let lost = try #require(Self.registryTestReduce(registered, .disappeared(record.identityKey)))
        let returning = try #require(Self.registryTestReduce(lost, .returned(record.identityKey)))
        let unknown = try Self.registryTestRecord(3).identityKey
        return [
            acceptedCase("register", empty, .observed(record), .registered(record.id)),
            acceptedCase(
                "duplicate observation", registered, .observed(record), nil,
                expectedRegistry: registered
            ),
            acceptedCase(
                "disappear", registered, .disappeared(record.identityKey),
                .lifecycleChanged(record.id, from: .present, to: .lostMuted)
            ),
            acceptedCase(
                "repeat disappearance", lost, .disappeared(record.identityKey), nil,
                expectedRegistry: lost
            ),
            acceptedCase(
                "return", lost, .returned(record.identityKey),
                .lifecycleChanged(record.id, from: .lostMuted, to: .revalidating)
            ),
            acceptedCase(
                "repeat return", returning, .returned(record.identityKey), nil,
                expectedRegistry: returning
            ),
            refusedCase("unknown device", registered, .returned(unknown), .unknownDevice(unknown)),
            refusedCase(
                "measurement while lost", lost,
                .capabilitiesMeasured(record.identityKey, try Self.registryTestMeasured()),
                .deviceNotAvailable(record.identityKey)
            )
        ]
    }

    private static func measurementEffectCases() throws -> [RegistryEffectCase] {
        let baseline = try Self.registryTestMeasured()
        let mismatch = try Self.registryTestMeasured(bufferFrames: 256)
        let record = try Self.registryTestRecord(4, measured: baseline)
        let unmeasured = try Self.registryTestRecord(5)
        let registered = try #require(Self.registryTestReduce(.empty, .observed(record)))
        let withUnmeasured = try #require(Self.registryTestReduce(
            registered, .observed(unmeasured)
        ))
        let lost = try #require(Self.registryTestReduce(
            registered, .disappeared(record.identityKey)
        ))
        let returning = try #require(Self.registryTestReduce(
            lost, .returned(record.identityKey)
        ))
        let mutedPresent = try #require(Self.registryTestReduce(
            registered, .capabilitiesMeasured(record.identityKey, mismatch)
        ))
        let mutedReturning = try #require(Self.registryTestReduce(
            returning, .capabilitiesMeasured(record.identityKey, mismatch)
        ))
        let baselineRecorded = try #require(Self.registryTestReduce(
            withUnmeasured, .capabilitiesMeasured(unmeasured.identityKey, baseline)
        ))
        let lostWithoutBaseline = try #require(Self.registryTestReduce(
            withUnmeasured, .disappeared(unmeasured.identityKey)
        ))
        let withoutBaseline = try #require(Self.registryTestReduce(
            lostWithoutBaseline, .returned(unmeasured.identityKey)
        ))
        let mutedWithoutBaseline = try #require(Self.registryTestReduce(
            withoutBaseline, .capabilitiesMeasured(unmeasured.identityKey, baseline)
        ))
        return [
            acceptedCase(
                "first measurement", withUnmeasured,
                .capabilitiesMeasured(unmeasured.identityKey, baseline),
                .capabilitiesMeasured(unmeasured.id)
            ),
            acceptedCase(
                "repeat matching measurement", baselineRecorded,
                .capabilitiesMeasured(unmeasured.identityKey, baseline), nil,
                expectedRegistry: baselineRecorded
            ),
            acceptedCase(
                "present mismatch", registered,
                .capabilitiesMeasured(record.identityKey, mismatch),
                .lifecycleChanged(
                    record.id, from: .present, to: .muted(.capabilityMismatch(.bufferFrames))
                )
            ),
            acceptedCase(
                "returning mismatch", returning,
                .capabilitiesMeasured(record.identityKey, mismatch),
                .lifecycleChanged(
                    record.id, from: .revalidating,
                    to: .muted(.capabilityMismatch(.bufferFrames))
                )
            ),
            acceptedCase(
                "repeat mismatch", mutedPresent,
                .capabilitiesMeasured(record.identityKey, mismatch), nil,
                expectedRegistry: mutedPresent
            ),
            acceptedCase(
                "matching muted record", mutedPresent,
                .capabilitiesMeasured(record.identityKey, baseline),
                .lifecycleChanged(
                    record.id, from: .muted(.capabilityMismatch(.bufferFrames)), to: .present
                )
            ),
            acceptedCase(
                "matching returning record", mutedReturning,
                .capabilitiesMeasured(record.identityKey, baseline),
                .lifecycleChanged(
                    record.id, from: .muted(.capabilityMismatch(.bufferFrames)), to: .present
                )
            ),
            acceptedCase(
                "missing baseline", withoutBaseline,
                .capabilitiesMeasured(unmeasured.identityKey, baseline),
                .lifecycleChanged(
                    unmeasured.id, from: .revalidating, to: .muted(.noMeasuredBaseline)
                )
            ),
            acceptedCase(
                "repeat missing baseline", mutedWithoutBaseline,
                .capabilitiesMeasured(unmeasured.identityKey, baseline), nil,
                expectedRegistry: mutedWithoutBaseline
            )
        ]
    }

    private static func replacementEffectCases() throws -> [RegistryEffectCase] {
        let record = try Self.registryTestRecord(6, measured: Self.registryTestMeasured())
        let replacement = try Self.registryTestRecord(
            6, measured: Self.registryTestMeasured(bufferFrames: 256)
        )
        let registered = try #require(Self.registryTestReduce(.empty, .observed(record)))
        return [
            acceptedCase(
                "replacement", registered, .replacingRecord(replacement), .replaced(record.id)
            ),
            acceptedCase(
                "identical replacement", registered, .replacingRecord(record), nil,
                expectedRegistry: registered
            )
        ]
    }

    private static func acceptedCase(
        _ name: String, _ registry: DeviceRegistry,
        _ event: DeviceRegistryEvent, _ effect: DeviceRegistryEffect?,
        expectedRegistry: DeviceRegistry? = nil
    ) -> RegistryEffectCase {
        RegistryEffectCase(
            name: name, registry: registry, event: event, expected: .accepted(effect),
            expectedRegistry: expectedRegistry
        )
    }

    private static func refusedCase(
        _ name: String, _ registry: DeviceRegistry,
        _ event: DeviceRegistryEvent, _ refusal: DeviceRegistryRefusal
    ) -> RegistryEffectCase {
        RegistryEffectCase(
            name: name, registry: registry, event: event, expected: .refused(refusal),
            expectedRegistry: nil
        )
    }
}
