//
//  OpenSoundControl+ReceiveContext.swift
//  FluxKlang
//
//  The receive context of an inbound OSC packet (#89, O2c): the peer it came from and the host epoch, connection
//  epoch and permission fingerprint the host had issued for that connection when the packet arrived. It names no
//  address and reads no clock. The host builds it from the principal it bound to the connection; the scheduler
//  wrapper (`OpenSoundControl+ContextScheduler.swift`) stores it with every batch the packet queued and compares it
//  with the live contexts at dispatch.
//

extension OpenSoundControl {
    /// What a packet was received under: the peer, the host epoch and connection epoch issued for that connection,
    /// and the permission fingerprint of the principal bound to it. Two contexts are equal only when all four fields
    /// are equal, so a reconnect (a new connection epoch), a host restart (a new host epoch) or a permission change
    /// (a new fingerprint) makes a different context, and a batch queued under the old one is no longer live.
    ///
    /// IP allowlists are not authentication. A context proves nothing about who a peer is: the peer key is the opaque
    /// key the host gave one datagram source or stream connection (it is not an address), and the epochs and the
    /// fingerprint are injected by the host, not read from the wire. The fingerprint stands for the principal's
    /// grants: the context holds it, not the grants, so a host that changes a principal's grants must issue a new
    /// fingerprint or the change goes unseen at dispatch. Grant checks stay in `Principal.admit` and
    /// `HostCommandGate`.
    struct ReceiveContext: Sendable, Hashable {
        private(set) var peer: PeerKey
        private(set) var hostEpoch: HostEpoch
        private(set) var connectionEpoch: ConnectionEpoch
        private(set) var permission: PermissionFingerprint

        private init(
            peer: PeerKey, hostEpoch: HostEpoch, connectionEpoch: ConnectionEpoch, permission: PermissionFingerprint
        ) {
            self.peer = peer
            self.hostEpoch = hostEpoch
            self.connectionEpoch = connectionEpoch
            self.permission = permission
        }

        /// The context of `peer` under `principal`: the principal's epochs and fingerprint, copied as they are.
        static func make(principal: Principal, peer: PeerKey) -> ReceiveContext {
            ReceiveContext(
                peer: peer, hostEpoch: principal.hostEpoch, connectionEpoch: principal.connectionEpoch,
                permission: principal.permission
            )
        }
    }
}
