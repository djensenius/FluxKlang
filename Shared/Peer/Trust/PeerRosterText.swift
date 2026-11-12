//
//  PeerRosterText.swift
//  FluxKlang
//
//  The fixed strings and builders of the host peer roster and pairing prompt
//  (#94 PEER1, #96). docs/transformation/workspace-ux/host-remote-roles.md
//  fixes only "Disconnected" (line 94), the "Revoke" action (line 82) and
//  "Pair request from ..." (line 88); the rest of the wording is a choice, kept
//  here so a rename shows in one place. No text contains identity bytes.
//  Nothing calls it yet.
//

enum PeerRosterText {
    static let revoke = "Revoke"
    static let disconnected = "Disconnected"
    static let noPairedPeers = "No paired peers"
    static let allow = "Allow"
    static let deny = "Deny"
    static let remoteController = "Remote controller"
    static let observer = "Observer"

    /// The role the host granted (or, in the prompt, the role requested), in the role table's wording.
    static func role(_ role: PeerRole) -> String {
        switch role {
        case .remoteController: remoteController
        case .observer: observer
        }
    }

    static func connected(epoch: Int) -> String { "Connected (epoch \(epoch))" }

    static func status(_ connection: PeerRosterConnection) -> String {
        switch connection {
        case .connected(let epoch): connected(epoch: epoch)
        case .disconnected: disconnected
        }
    }

    /// The status as spoken: "connected, epoch 4" or "disconnected".
    static func spokenStatus(_ connection: PeerRosterConnection) -> String {
        switch connection {
        case .connected(let epoch): "connected, epoch \(epoch)"
        case .disconnected: "disconnected"
        }
    }

    static func rowAccessibility(name: String, role: PeerRole, connection: PeerRosterConnection) -> String {
        "\(name), \(Self.role(role)), \(spokenStatus(connection))."
    }

    static func revokeAccessibility(name: String) -> String { "\(revoke) \(name)" }

    static func pairRequest(name: String) -> String { "Pair request from \(name)" }

    static func requestedRole(_ role: PeerRole) -> String { "Requested role: \(Self.role(role))" }

    static func pairAccessibility(name: String, role: PeerRole) -> String {
        "\(pairRequest(name: name)). \(requestedRole(role))."
    }
}
