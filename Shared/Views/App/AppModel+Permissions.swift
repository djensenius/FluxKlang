//
//  AppModel+Permissions.swift
//  FluxKlang
//
//  Keeps launch prompt-free: the remembered WING is reconnected at startup only
//  when the user opted in and this app already reached it after a user action
//  on this device. The live connect path records that evidence on success and
//  drops it after a possibly-denied probe for the same host.
//

import Foundation

extension AppModel {
    static let reconnectAtLaunchKey = "fluxklang.reconnectAtLaunch"

    /// "Reconnect to last WING at launch". Off by default: the default launch
    /// performs no network activity at all.
    var reconnectsAtLaunch: Bool {
        get { AppPersistence.defaults.bool(forKey: Self.reconnectAtLaunchKey) }
        set { AppPersistence.defaults.set(newValue, forKey: Self.reconnectAtLaunchKey) }
    }

    func allowsStartupReconnect(
        evidence: LocalNetworkGrantEvidence? = nil,
        isTesting: Bool = AppPersistence.isTesting,
        isUITesting: Bool = AcceptanceLaunchConfiguration.isUITesting
    ) -> Bool {
        let evidence = evidence ?? hardware.localNetworkEvidence
        return StartupReconnectPolicy(
            userOptedIn: reconnectsAtLaunch,
            isTesting: isTesting,
            isUITesting: isUITesting,
            isConnected: isConnected,
            hasLastHost: lastHost != nil,
            hasLocalNetworkGrant: lastHost.map(evidence.hasGrant(for:)) ?? false
        ).shouldReconnect
    }

    /// The controller for `connect(host:)`. Its transport runs the Local Network
    /// pre-flight; a possible denial for `host` clears stale startup evidence so
    /// launch can't keep retrying a host the user may have blocked.
    func makeLiveController(host: String, port: UInt16) -> WingController {
        let probe = hardware.localNetworkProbe, evidence = hardware.localNetworkEvidence
        let transport = hardware.makeWingTransport(port) { peer, peerPort in
            let code = probe(peer, peerPort)
            if LocalNetworkAccess.status(afterConnectErrno: code) == .possiblyDenied {
                evidence.clear(host: host)
            }
            return code
        }
        return WingController(transport: transport, port: port)
    }

    /// Called after a user-initiated or evidence-gated live connect succeeded.
    func rememberConnectedHost(_ host: String) {
        lastHost = host
        hardware.localNetworkEvidence.recordGrant(for: host)
    }
}
