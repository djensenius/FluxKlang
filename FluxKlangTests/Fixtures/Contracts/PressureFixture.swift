//
//  PressureFixture.swift
//  FluxKlangTests
//
//  Contract values at their resource limits, built through the real contract
//  APIs: a full trigger session, a full readiness store, the largest trigger
//  dependency list and a device document at its device-count limit.
//

@testable import FluxKlang

/// Why a pressure fixture could not be built.
enum PressureFixtureError: Error, Equatable, Sendable {
    case session(TriggerSessionError)
    case ids(FixtureIDSequenceError)
    case readiness(ReadinessFixtureError)
}

/// Saturated contract values. Every builder is deterministic: IDs come from
/// fixed literals or `FixtureIDSequence`, generations start at `.initial`, and
/// nothing reads the clock, generates random values or touches files.
enum PressureFixture {
    /// The largest session `saturatedSession` builds: one trigger ID per slot,
    /// from a single `FixtureIDSequence`. The contract allows up to 65,536.
    static var maximumSessionCapacity: Int { FixtureIDSequence<TriggerTag>.maximumLimit }

    /// `TriggerSession(outcomeCapacity: capacity)` with every slot reserved by
    /// `fx.trigger.1…<capacity>`, in that order. Any new identity is refused
    /// with `outcomeCapacity`. A capacity outside `1...maximumSessionCapacity`
    /// throws `.session(.invalidOutcomeCapacity)` or `.ids(.invalidLimit)`.
    static func saturatedSession(
        capacity: Int
    ) throws(PressureFixtureError) -> (TriggerSession, [TriggerHandle]) {
        var session: TriggerSession
        var ids: FixtureIDSequence<TriggerTag>
        do { session = try TriggerSession(outcomeCapacity: capacity) } catch { throw .session(error) }
        do { ids = try FixtureIDSequence(prefix: "trigger", limit: capacity) } catch { throw .ids(error) }
        var handles: [TriggerHandle] = []
        handles.reserveCapacity(capacity)
        for _ in 0..<capacity {
            let id: TriggerID
            do { id = try ids.next() } catch { throw .ids(error) }
            do { try handles.append(session.reserve(id: id, session: session.currentToken)) } catch {
                throw .session(error)
            }
        }
        return (session, handles)
    }

    /// The readiness store of `ReadinessFixture.make(.pressured)`: `fx.action`
    /// ready plus `fx.pressure.1…4095` preparing, so it holds 4,096 actions and
    /// refuses any new one with `capacity`. It reuses that fixture rather than
    /// building a second full store.
    static func readinessAtCapacity() throws(PressureFixtureError) -> ActionReadiness {
        do { return try ReadinessFixture.make(.pressured).readiness } catch { throw .readiness(error) }
    }

    /// Exactly `TriggerStamp.maximumRequirements` (8) distinct requirements at
    /// `.initial`, valid for a trigger whose primary clock is
    /// `ReadinessFixture.primaryKey` and musical clock is `fx.clock.musical`:
    /// the primary sample clock, the musical transport, the fixture source and
    /// context, two more sources, one more context and one cancel scope. There
    /// is no musical-map key, which a trigger may never require (M3).
    static func maximumRequirements() -> [GenerationRequirement] {
        let keys = ReadinessFixture.dependencyKeys + [
            GenerationKey(.transport, ContractFixtureIDs.musicalClock),
            GenerationKey(.source, StreamID(validated: "fx.pressure.stream.1")),
            GenerationKey(.source, StreamID(validated: "fx.pressure.stream.2")),
            GenerationKey(.context, GenerationSubject(validated: "fx.pressure.context.1")),
            GenerationKey(.cancelScope, GenerationSubject(validated: "fx.pressure.scope.1"))
        ]
        return keys.map { GenerationRequirement(key: $0, generation: .initial) }
    }

    /// A valid requirement on a key `maximumRequirements()` does not use, so a
    /// ninth entry is refused for its count, never as a duplicate.
    static let overflowRequirement = GenerationRequirement(
        key: GenerationKey(.cancelScope, GenerationSubject(validated: "fx.pressure.scope.2")), generation: .initial
    )

    /// The device-count limit, `DeviceCapabilityLimits.devices` (1,024). It is
    /// the document's top-level count and is reached with small descriptors:
    /// 1,024 of them encode to well under the 4 MiB `documentBytes` ceiling and
    /// need no routes. The route limit would also need devices, layouts and
    /// route checks, and the per-device capability limit is a nested count.
    static var deviceLimit: Int { DeviceCapabilityLimits.devices }

    /// A document for `fx.host` at host epoch `.initial` with exactly
    /// `deviceLimit` devices from `devices(count:)` and no routes.
    static func documentAtDeviceLimit() throws -> DeviceCapabilityDocument {
        try DeviceCapabilityDocument(
            revision: .initial, host: ContractFixtureIDs.host, hostEpoch: .initial,
            devices: devices(count: deviceLimit), routes: []
        )
    }

    /// `fx.pressure.device.1…<count>`: present, unverified audio interfaces with
    /// no layout or capabilities and a distinct per-device UID. Use
    /// `devices(count: deviceLimit + 1)` to build a list one past the limit;
    /// `count` is bounded by `FixtureIDSequence.maximumLimit`.
    static func devices(count: Int) throws -> [DeviceDescriptor] {
        var ids = try FixtureIDSequence<DeviceTag>(prefix: "pressure.device", limit: count)
        return try (1...count).map { index in
            try DeviceDescriptor(
                id: ids.next(), kind: .audioInterface, layout: nil, binding: .unverified,
                identity: DeviceIdentity(.init(uid: "fx-pressure-uid-\(index)", evidence: [.deviceUID]))
            )
        }
    }
}
