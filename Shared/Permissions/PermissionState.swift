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
    /// Confirmed by the OS (for example microphone TCC). Never inferred from a socket error.
    case denied
    /// A local-network probe failed with an errno that a denial *or* an ordinary
    /// network fault can produce. iOS offers no API to tell them apart (TN3179).
    case possiblyDenied
    /// No interface or route can reach the host: not a permission problem.
    case unreachable
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
        case (.localNetwork, .possiblyDenied):
            return "Can't reach the WING. Check that this device is on the WING's network. If it is, "
                + "Local Network access may be off for FluxKlang: allow it in "
                + "\(LocalNetworkAccess.settingsPath), then try again."
        case (.localNetwork, .unreachable):
            return "This device isn't connected to a network that can reach the WING. "
                + "Join the WING's network and try again."
        case (.multicast, .unsupported):
            return "Automatic WING discovery isn't available in this build. Enter the WING's IP address instead."
        case (_, .unsupported):
            return "\(name) isn't used by this version of FluxKlang."
        case (_, .notDetermined):
            return "FluxKlang asks for \(name) access only when you turn on a feature that needs it."
        case (_, .unreachable), (_, .possiblyDenied):
            return "\(name) couldn't be used right now. Check the connection and try again."
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
    /// errnos meaning no interface or route reaches the host (Wi-Fi off, not
    /// joined yet). These are reported as a network problem, never a denial.
    static let unreachableErrnos: Set<Int32> = [ENETUNREACH, ENETDOWN, EADDRNOTAVAIL]
    /// errnos a denied or undetermined privilege may produce, but that also have
    /// ordinary causes: EHOSTUNREACH (reject route, interface going down),
    /// EACCES (a broadcast address without SO_BROADCAST), EPERM (packet or
    /// content filter). Which one a denial returns is undocumented (Unknown).
    static let possibleDenialErrnos: Set<Int32> = [EHOSTUNREACH, EPERM, EACCES]

    /// A successful connect only shows the path wasn't blocked; for a routed
    /// (non-local) host the privilege doesn't apply, so `.granted` is evidence,
    /// not confirmation.
    static func status(afterConnectErrno code: Int32?) -> PermissionStatus {
        guard let code else { return .granted }
        if unreachableErrnos.contains(code) { return .unreachable }
        return possibleDenialErrnos.contains(code) ? .possiblyDenied : .unknown
    }

    static var settingsPath: String {
        #if os(macOS)
        "System Settings › Privacy & Security › Local Network"
        #else
        "Settings › Privacy & Security › Local Network"
        #endif
    }

    /// User-facing text for a failed pre-flight connect to `host`. Names every
    /// plausible cause; never claims the Local Network toggle is the cause.
    static func connectFailureReason(errno code: Int32, host: String) -> String {
        switch status(afterConnectErrno: code) {
        case .unreachable:
            return "This device isn't connected to a network that can reach \(host). "
                + "Join the WING's network and try again."
        case .possiblyDenied:
            return "Can't reach \(host). Check that this device is on the WING's network. If it is, "
                + "Local Network access may be off for FluxKlang: allow it in \(settingsPath), then try again."
        default:
            return "Couldn't open a network path to \(host) (\(String(cString: strerror(code))))."
        }
    }

    /// The errno that best explains a scan whose sends all failed, independent of
    /// interface order: a possible denial wins, then a missing route, then any
    /// other recorded errno.
    static func dominantErrno(_ codes: [Int32?]) -> Int32? {
        let recorded = codes.compactMap { $0 }
        return recorded.first { status(afterConnectErrno: $0) == .possiblyDenied }
            ?? recorded.first { status(afterConnectErrno: $0) == .unreachable }
            ?? recorded.first
    }

    /// User-facing text for a broadcast scan that couldn't send. Uses the same
    /// errno vocabulary as `connectFailureReason`. A possible denial never
    /// suggests manual IP entry: that path is checked the same way and would
    /// fail too. Only unclassified failures offer the IP fallback.
    static func discoveryFailureReason(errno code: Int32?) -> String {
        switch code.map(status(afterConnectErrno:)) {
        case .unreachable:
            return "This device isn't connected to a network that can reach the WING. "
                + "Join the WING's network and scan again."
        case .possiblyDenied:
            return "The scan couldn't send. Check that this device is on the WING's network. If it is, "
                + "Local Network access may be off for FluxKlang: allow it in \(settingsPath), then scan again."
        default:
            let detail = code.map { " (\(String(cString: strerror($0))))" } ?? ""
            return "The scan couldn't send on this network\(detail). Try again, or enter the WING's IP address."
        }
    }

    /// The POSIX errno behind a socket error, if one is recorded. Swift-NIO's
    /// `IOError` (thrown through SwiftOSC) stores it privately as `error: .errno(CInt)`.
    static func errno(in error: any Error, depth: Int = 3) -> Int32? {
        if let posix = error as? POSIXError { return posix.code.rawValue }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        return errnoField(in: Mirror(reflecting: error), depth: depth)
    }

    private static func errnoField(in mirror: Mirror, depth: Int) -> Int32? {
        guard depth > 0 else { return nil }
        for child in mirror.children {
            if child.label == "errno" || child.label == "errnoCode", let code = child.value as? Int32 {
                return code
            }
            if let nested = child.value as? any Error, let code = errno(in: nested, depth: depth - 1) {
                return code
            }
            if let code = errnoField(in: Mirror(reflecting: child.value), depth: depth - 1) { return code }
        }
        return nil
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
/// (for example after a backup restore, Reset Location & Privacy, a first
/// launch on macOS 15+, or a new signing identity). Launch reconnect is
/// therefore opt-in (off by default), and even when opted in it still needs
/// on-device evidence that this app already reached that host after a user action.
struct StartupReconnectPolicy {
    var userOptedIn: Bool
    var isTesting: Bool
    var isUITesting: Bool
    var isConnected: Bool
    var hasLastHost: Bool
    var hasLocalNetworkGrant: Bool

    var shouldReconnect: Bool {
        userOptedIn && !isTesting && !isUITesting && !isConnected && hasLastHost && hasLocalNetworkGrant
    }
}
