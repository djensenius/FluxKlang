//
//  PeerRosterPairPrompt.swift
//  FluxKlang
//
//  The host's pairing prompt as a value (#94 PEER1, #96; host-remote-roles.md
//  lines 81 and 88): "Pair request from Remote C" with Allow and Deny, no
//  default button and Escape denies. It carries no grants: the host chooses
//  them explicitly (`PeerPairingDecision.allow`). The form factor line 81 names
//  and the confirmation code are not in `PeerPairingRequest`, so they are not
//  shown. Nothing calls it yet.
//

enum PeerRosterPromptChoice: Hashable, Sendable, CaseIterable {
    case allow
    case deny

    var title: String {
        switch self {
        case .allow: PeerRosterText.allow
        case .deny: PeerRosterText.deny
        }
    }
}

struct PeerRosterPairPrompt: Hashable, Sendable {
    /// The peer's label, verbatim; `make` refuses labels the store would refuse.
    let peerName: String
    /// What the peer asked for, never what the host grants.
    let requestedRole: PeerRole
    let choices: [PeerRosterPromptChoice]
    let escapeChoice: PeerRosterPromptChoice

    private init(peerName: String, requestedRole: PeerRole) {
        self.peerName = peerName
        self.requestedRole = requestedRole
        choices = [.allow, .deny]
        escapeChoice = .deny
    }

    var title: String { PeerRosterText.pairRequest(name: peerName) }
    var detail: String { PeerRosterText.requestedRole(requestedRole) }
    var accessibilityLabel: String { PeerRosterText.pairAccessibility(name: peerName, role: requestedRole) }

    static func make(_ request: PeerPairingRequest) throws(PeerRosterRefusal) -> PeerRosterPairPrompt {
        guard PeerPairingLabelRule.isValid(request.label) else { throw .invalidLabel }
        return PeerRosterPairPrompt(peerName: request.label, requestedRole: request.requestedRole)
    }
}
