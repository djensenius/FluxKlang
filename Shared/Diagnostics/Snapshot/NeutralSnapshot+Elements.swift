//
//  NeutralSnapshot+Elements.swift
//  FluxKlang
//
//  The read-only element values of a `NeutralSnapshot`. Each copies only the
//  neutral, bounded facts of its source contract.
//

import Foundation

extension NeutralSnapshot {
    struct Port: Hashable, Sendable, Encodable {
        let id: PortID
        let direction: PortDirection
        let signal: PortSignal
        let channels: Int?
        let label: UntrustedLabel?
    }

    struct Node: Hashable, Sendable, Encodable {
        let id: NodeID
        let kind: NodeKind
        let label: UntrustedLabel
        let role: RoleID?
        let asset: AssetID?
        let graph: GraphID?
        let muted: Bool?
        /// Sorted by port ID and capped by `Limits.portsPerNode`.
        let ports: [Port]
        let portCount: CategoryCount
    }

    /// A port addressed through its node, without extension fields.
    struct Endpoint: Hashable, Sendable, Encodable {
        let node: NodeID
        let port: PortID
    }

    struct Edge: Hashable, Sendable, Encodable {
        let id: EdgeID
        let from: Endpoint
        let to: Endpoint
        let hasConversion: Bool
        let isFeedback: Bool

        func touches(_ endpoint: Endpoint) -> Bool {
            from == endpoint || to == endpoint
        }
    }

    struct Parameter: Hashable, Sendable, Encodable {
        let id: ParameterID
        let node: NodeID?
        let unit: ParameterUnit
        let lower: Double
        let upper: Double
        let defaultValue: Double
        let ceiling: Double?
        let curve: ParameterCurve
        let controlClass: ControlClass
        let verification: MeasurementStatus
    }

    /// Whether a host route can currently carry signal, as far as the snapshot knows.
    enum RouteAvailability: String, Hashable, Sendable, Encodable, CaseIterable {
        /// Confirmed on this host and its device is present.
        case available
        /// The device is present but the binding is only proposed, not confirmed.
        case unconfirmed
        /// The binding or the device observation is stale.
        case stale
        /// The binding or the device observation says the device is missing.
        case deviceMissing
        /// The host has no observation of the route's device.
        case deviceUnobserved
    }

    /// A host route by neutral IDs only. Hardware UIDs, host bindings and
    /// evidence text are never copied; `device` is shown only when it passes the
    /// project-alias allowlist (`NeutralSnapshotAssembly.isNeutralDeviceAlias`).
    struct Route: Hashable, Sendable, Encodable {
        let id: RouteID
        let role: RoleID
        let device: DeviceID?
        let isDeviceWithheld: Bool
        let direction: RouteDirection
        let channelCount: Int
        let binding: RouteBinding
        let presence: DevicePresence?
        let availability: RouteAvailability
    }

    struct Diagnostic: Hashable, Sendable, Encodable {
        let id: DiagnosticID
        let severity: DiagnosticSeverity
        let summary: UntrustedLabel
        let subject: DiagnosticSubject?
        /// False when the subject names an element that is not in this snapshot
        /// (dropped, dangling or never offered). True when there is no subject.
        let subjectInSnapshot: Bool
    }
}
