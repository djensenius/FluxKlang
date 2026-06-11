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

    /// A short, human-readable description for display.
    var statusLabel: String {
        switch self {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let name): return name.map { "Connected — \($0)" } ?? "Connected"
        case .failed(let reason): return "Connection failed — \(reason)"
        }
    }
}
