//
//  PermissionState.swift
//  FluxKlang
//
//  Pure, testable permission model. Nothing here queries or requests a system
//  permission; see `PermissionProbe` for the (explicit, user-initiated) side.
//  Decisions and sources: docs/transformation/permissions.md.
//

import Darwin
import Foundation

/// Privacy-gated capabilities FluxKlang uses or deliberately does not declare yet.
enum PermissionCapability: String, CaseIterable, Sendable {
    /// Unicast OSC/UDP to the WING (TN3179 Local Network privilege).
    case localNetwork
    /// Audio input from a microphone or interface (no input feature ships yet).
    case microphone
    /// Not declared: no Bluetooth/BLE-MIDI feature ships yet.
    case bluetooth
    /// Broadcast/multicast. Required on iOS for WING broadcast discovery; Apple-gated.
    case multicast

    var displayName: String {
        switch self {
        case .localNetwork: return "Local Network"
        case .microphone: return "Microphone"
        case .bluetooth: return "Bluetooth"
        case .multicast: return "Network discovery"
        }
    }
}

enum PermissionStatus: String, Sendable {
    case notDetermined
    case denied
    case restricted
    case granted
    /// The OS offers no query for this capability, or no evidence exists yet.
    case unknown
    /// This build does not declare, or is not entitled to, the capability.
    case unsupported
}

struct PermissionState: Equatable, Sendable {
    let capability: PermissionCapability
    let status: PermissionStatus

    /// Whether the capability can be used right now without a system prompt.
    var isUsable: Bool { status == .granted }

    /// Truthful, user-facing explanation. Never claims more than is known.
    var reason: String {
        let name = capability.displayName
        switch (capability, status) {
        case (_, .granted):
            return "\(name) access is allowed."
        case (.localNetwork, .notDetermined), (.localNetwork, .unknown):
            return "FluxKlang asks for Local Network access the first time you connect to a WING."
        case (.localNetwork, .denied):
            return "Local Network access is off for FluxKlang, or the access prompt hasn't been answered. "
                + "Allow FluxKlang under Privacy & Security › Local Network in Settings, then try again."
        case (.multicast, .unsupported):
            return "Automatic WING discovery isn't available in this build. Enter the WING's IP address instead."
        case (_, .unsupported):
            return "\(name) isn't used by this version of FluxKlang."
        case (_, .notDetermined):
            return "FluxKlang asks for \(name) access only when you turn on a feature that needs it."
        case (_, .denied):
            return "\(name) access is off for FluxKlang. You can allow it under Privacy & Security in Settings."
        case (_, .restricted):
            return "\(name) access is restricted on this device and can't be changed from FluxKlang."
        case (_, .unknown):
            return "\(name) access hasn't been checked yet."
        }
    }
}

/// The Local Network privilege has no query API (TN3179), so its status is
/// inferred only from the outcome of a user-initiated operation.
enum LocalNetworkAccess {
    /// errno values a connect to a local address may return when the privilege
    /// is denied or still undetermined. Apple does not document the exact code
    /// (Unknown; covered by the operator checklist), so the set is conservative.
    static let denialErrnos: Set<Int32> = [EHOSTUNREACH, ENETUNREACH, EPERM, EACCES]

    static func status(afterConnectErrno code: Int32?) -> PermissionStatus {
        guard let code else { return .granted }
        return denialErrnos.contains(code) ? .denied : .unknown
    }

    /// Flip only together with project.yml once Apple grants
    /// com.apple.developer.networking.multicast for this App ID.
    static let hasMulticastEntitlement = false

    /// Broadcast discovery needs the Apple-approved multicast entitlement on
    /// iOS (TN3179); macOS does not require it.
    static func broadcastDiscovery(isIOS: Bool, hasMulticastEntitlement: Bool = hasMulticastEntitlement)
        -> PermissionState {
        let blocked = isIOS && !hasMulticastEntitlement
        return PermissionState(capability: .multicast, status: blocked ? .unsupported : .unknown)
    }

    static var currentBroadcastDiscovery: PermissionState {
        #if os(iOS)
        broadcastDiscovery(isIOS: true)
        #else
        broadcastDiscovery(isIOS: false)
        #endif
    }
}

/// Whether launch may reconnect to the remembered WING. A launch-time unicast
/// while the Local Network privilege is undetermined raises the system prompt
/// (for example after a backup restore, a first launch on macOS 15+, or a new
/// signing identity), so production reconnects only with on-device evidence
/// that this build already reached the network after a user action.
enum StartupReconnectPolicy {
    static func shouldReconnect(
        isTesting: Bool,
        isUITesting: Bool,
        isConnected: Bool,
        hasLastHost: Bool,
        hasLocalNetworkGrant: Bool
    ) -> Bool {
        !isTesting && !isUITesting && !isConnected && hasLastHost && hasLocalNetworkGrant
    }
}
