//
//  AdmissionContextFixture.swift
//  FluxKlangTests
//
//  Admission contexts and intents built from `CapabilitySnapshotFixture`. The
//  context sits at the snapshot's current host epoch; the intent was formed
//  against the epoch the snapshot was observed under, so only the stale state
//  disagrees. Admission never reads capabilities: missing, failed and
//  pressured snapshots still admit, and capability gating stays with
//  `assess` and `validateForPreparation`.
//

@testable import FluxKlang

enum AdmissionContextFixture {
    static let permission = PermissionFingerprint(rawValue: "fx.permission")
    static let connection = ConnectionID(validated: "fx.connection")
    static let command = CommandID(validated: "fx.command")
    static let parameter = ParameterID(validated: "fx.parameter")
    static let route = RouteID(validated: "fx.route")
    static let draft = DraftID(validated: "fx.draft")

    /// A context that allows exactly `controlClass` and the scope of its default operation.
    static func context(
        _ state: ContractFixtureState, controlClass: ControlClass,
        permission: PermissionFingerprint? = Self.permission
    ) throws -> AdmissionContext {
        let snapshot = try CapabilitySnapshotFixture.make(state)
        let host = HostEpoch(host: snapshot.document.host, generation: snapshot.currentHostEpoch)
        return AdmissionContext(
            hostEpoch: host, connectionEpoch: connectionEpoch(host), revisions: revisions(snapshot),
            permission: permission, allowedScopes: [operation(for: controlClass).scope],
            allowedClasses: [controlClass], catalog: try catalog(for: controlClass)
        )
    }

    static func intent(
        _ state: ContractFixtureState, controlClass: ControlClass,
        origin: CommandOrigin = .human, operation explicit: CommandOperation? = nil
    ) throws -> CommandIntent {
        let snapshot = try CapabilitySnapshotFixture.make(state)
        let host = HostEpoch(host: snapshot.document.host, generation: snapshot.document.hostEpoch)
        return try CommandIntent(.init(
            id: command, commandClass: controlClass, origin: origin, hostEpoch: host,
            connectionEpoch: connectionEpoch(host), revisions: revisions(snapshot),
            operation: explicit ?? operation(for: controlClass), permission: permission
        ))
    }

    /// The default operation for each class; live and hazardous set the fixture parameter.
    static func operation(for controlClass: ControlClass) -> CommandOperation {
        switch controlClass {
        case .live, .hazardous: .set(parameter, ParameterValue(value: 0.5, unit: .normalized))
        case .structural: .bind(route)
        case .safety: .panic
        case .proposal: .propose(draft)
        }
    }

    /// Always `.initial`: a host-epoch bump does not stale the connection here.
    /// Admission refuses on the host epoch before it compares connection epochs.
    private static func connectionEpoch(_ host: HostEpoch) -> ConnectionEpoch {
        ConnectionEpoch(connection: connection, host: host.host, generation: .initial)
    }

    private static func revisions(_ snapshot: CapabilitySnapshotFixture) -> CommandRevisions {
        CommandRevisions(capability: snapshot.document.revision)
    }

    private static func catalog(for controlClass: ControlClass) throws -> ParameterCatalog {
        let descriptor = try ParameterDescriptor(.init(
            id: parameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: nil,
            curve: .linear, ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 0, maximumMilliseconds: 100)),
            controlClass: controlClass == .hazardous ? .hazardous : .live, verification: .reported
        ))
        return try ParameterCatalog([descriptor])
    }
}
