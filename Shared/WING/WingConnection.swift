//
//  WingConnection.swift
//  FluxKlang
//
//  Connection lifecycle state for the WING link.
//

import Foundation

/// The lifecycle states of the WING connection.
enum WingConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(name: String?)
    case failed(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
