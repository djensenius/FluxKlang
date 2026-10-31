//
//  AppModel+Permissions.swift
//  FluxKlang
//
//  Keeps launch prompt-free: the remembered WING is reconnected at startup only
//  when this build already reached it after a user action on this device.
//

import Foundation

extension AppModel {
    var allowsStartupReconnect: Bool {
        StartupReconnectPolicy.shouldReconnect(
            isTesting: AppPersistence.isTesting,
            isUITesting: AcceptanceLaunchConfiguration.isUITesting,
            isConnected: isConnected,
            hasLastHost: lastHost != nil,
            hasLocalNetworkGrant: lastHost.map(LocalNetworkGrantEvidence.current.hasGrant(for:)) ?? false
        )
    }

    /// Called after a user-initiated or evidence-gated live connect succeeded.
    func rememberConnectedHost(_ host: String) {
        lastHost = host
        LocalNetworkGrantEvidence.current.recordGrant(for: host)
    }
}
