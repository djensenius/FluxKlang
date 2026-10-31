//
//  WingTransport.swift
//  FluxKlang
//
//  Low-level OSC/UDP transport for the WING. Wraps a bidirectional SwiftOSC UDP
//  socket — the WING replies to the sender's port — and surfaces incoming
//  messages as an AsyncStream. The WING accepts many simultaneous clients, so
//  this transport coexists with the WING Co-Pilot app and other controllers.
//

import Foundation
import SwiftOSC
import Darwin

/// An OSC message received from the WING.
struct WingIncoming: Sendable {
    let address: String
    let values: [WingValue]
    let host: String
    let port: UInt16
    let transportSessionID: UUID?
    let receivedAt: Date

    /// The semantic value represented by a WING reply.
    ///
    /// Live WING GET replies commonly include a display string, a normalized
    /// float and an engineering value. Demo and SET echoes use one value.
    var effectiveValue: WingValue? {
        WingReplyResolver.resolve(address: address, values: values)
    }

    init(address: String, values: [WingValue], host: String, port: UInt16,
         transportSessionID: UUID? = nil, receivedAt: Date = Date()) {
        self.address = address
        self.values = values
        self.host = host
        self.port = port
        self.transportSessionID = transportSessionID
        self.receivedAt = receivedAt
    }

    init(address: String, value: WingValue?, host: String, port: UInt16,
         transportSessionID: UUID? = nil, receivedAt: Date = Date()) {
        self.init(address: address, values: value.map { [$0] } ?? [], host: host, port: port,
                  transportSessionID: transportSessionID, receivedAt: receivedAt)
    }
}

enum WingReplyResolver {
    static func resolve(address: String, values: [WingValue]) -> WingValue? {
        guard values.count > 1 else { return values.first }
        guard values.count >= 3,
              values[0].stringValue != nil,
              values[1].floatValue != nil else {
            return values.first
        }

        if let actual = values[2].floatValue {
            return address.hasSuffix("/fdr") ? values[1] : .float(actual)
        }

        if let actual = values[2].intValue {
            if isOneBasedSourceIndex(address),
               let display = values[0].stringValue,
               let oneBased = Int32(display) {
                return .int(oneBased)
            }
            return .int(actual)
        }

        return values.first
    }

    private static func isOneBasedSourceIndex(_ address: String) -> Bool {
        address.hasSuffix("/in/conn/in")
            || (address.hasPrefix("/io/out/") && address.hasSuffix("/in"))
    }
}

enum WingTransportError: Error, Equatable, Sendable {
    case notStarted
    case notAuthorized
    case unresolvedPeer
    /// The pre-flight UDP connect to the console failed (see `LocalNetworkProbe`).
    case localNetworkBlocked(errno: Int32)
}

extension WingTransportError: LocalizedError {
    var errorDescription: String? {
        guard case .localNetworkBlocked(let code) = self else { return nil }
        let status = LocalNetworkAccess.status(afterConnectErrno: code)
        if status == .denied {
            return PermissionState(capability: .localNetwork, status: .denied).reason
        }
        return "Couldn't open a network path to the WING (\(String(cString: strerror(code))))."
    }
}

/// TN3179: connecting a UDP socket is a Local Network-checked operation that
/// sends no packets, so it reveals a denial before the app claims a link.
enum LocalNetworkProbe {
    /// Returns the connect errno, or nil when the path is allowed.
    @Sendable static func connectErrno(ipv4 host: String, port: UInt16) -> Int32? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 ? nil : errno
    }
}

/// Actor that owns the UDP socket and serialises all access to it.
actor WingTransport: WingTransporting {
    /// The WING OSC port this transport sends to.
    let remotePort: UInt16

    /// Stream of messages received from the WING (value changes, query replies).
    nonisolated let incoming: AsyncStream<WingIncoming>

    private let continuation: AsyncStream<WingIncoming>.Continuation
    private var socket: OSCUDPSocket?
    private(set) var sessionID: UUID?
    private(set) var peerHosts: Set<String> = []

    private let localNetworkProbe: @Sendable (String, UInt16) -> Int32?

    init(remotePort: UInt16 = WingNetwork.defaultPort,
         localNetworkProbe: @escaping @Sendable (String, UInt16) -> Int32? = LocalNetworkProbe.connectErrno) {
        self.remotePort = remotePort
        self.localNetworkProbe = localNetworkProbe
        (incoming, continuation) = AsyncStream.makeStream(of: WingIncoming.self)
    }

    deinit {
        continuation.finish()
    }

    /// Opens the socket and begins receiving. `broadcast` enables IPv4 broadcast
    /// on the local port for discovery.
    func start(remoteHost: String, localPort: UInt16? = nil, broadcast: Bool = false) throws {
        stopSocket()
        let continuation = continuation
        let sessionID = UUID()
        let peers = WingPeerIdentity.ipv4Addresses(for: remoteHost)
        guard broadcast || !peers.isEmpty else { throw WingTransportError.unresolvedPeer }
        // A manual IP takes the same checked path as discovery: a denial is reported, not bypassed.
        for peer in peers.sorted() where !broadcast {
            guard let code = localNetworkProbe(peer, remotePort) else { continue }
            throw WingTransportError.localNetworkBlocked(errno: code)
        }
        let expectedPort = remotePort
        let socket = OSCUDPSocket(
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            interface: nil,
            isIPv4BroadcastEnabled: broadcast,
            isIPv6Enabled: false,
            queue: nil,
            receiveHandler: .messages { message, _, host, port in
                guard broadcast || (peers.contains(host) && port == expectedPort) else { return }
                continuation.yield(
                    WingIncoming(
                        address: message.addressPattern.stringValue,
                        values: message.values.compactMap(WingValue.init(osc:)),
                        host: host,
                        port: port,
                        transportSessionID: sessionID
                    )
                )
            }
        )
        try socket.start()
        self.socket = socket
        self.sessionID = sessionID
        self.peerHosts = peers
    }

    func stop() {
        stopSocket()
    }

    /// Sends an OSC message. A `nil` value sends the address with no arguments,
    /// which the WING treats as a query (GET) and answers with the current value
    /// on the incoming stream.
    func send(
        _ address: String,
        _ value: WingValue? = nil,
        to host: String? = nil,
        port: UInt16? = nil
    ) throws {
        guard let socket else { throw WingTransportError.notStarted }
        let values: OSCValues = value.map { [$0.oscValue] } ?? []
        try socket.send(.message(OSCMessage(address, values: values)), to: host, port: port)
    }

    func sendMixerValue(_ node: WingNodeRef, value: WingValue, muted: Bool, sessionID: UUID,
                        authorization: WingMixerWriteAuthorization) throws {
        try authorization.consume(node: node, value: value, muted: muted) {
            // No suspension between authorization/session checks and the socket write.
            guard self.sessionID == sessionID,
                  WingController.isValidMixerValue(node, value: value, muted: muted) else {
                throw WingTransportError.notAuthorized
            }
            let address = muted ? WingAddress.mute(node.kind, node.index) : WingAddress.fader(node.kind, node.index)
            try send(address, value.encodedForWing(address: address))
        }
    }

    private func stopSocket() {
        socket?.stop()
        socket = nil
        sessionID = nil
        peerHosts = []
    }
}

/// WING transport is IPv4-only. Resolve hostnames before accepting replies;
/// never accept the first arbitrary sender as the console's identity.
enum WingPeerIdentity {
    static func ipv4Addresses(for host: String) -> Set<String> {
        guard !host.isEmpty, !host.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { return [] }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var addresses = Set<String>()
        var cursor = result
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                if let address = String(bytes: bytes, encoding: .utf8) { addresses.insert(address) }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}
