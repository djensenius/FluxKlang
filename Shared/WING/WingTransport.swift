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

/// An OSC message received from the WING.
struct WingIncoming: Sendable {
    let address: String
    let value: WingValue?
    let host: String
    let port: UInt16
}

enum WingTransportError: Error, Sendable {
    case notStarted
}

/// Actor that owns the UDP socket and serialises all access to it.
actor WingTransport: WingTransporting {
    /// The WING OSC port this transport sends to.
    let remotePort: UInt16

    /// Stream of messages received from the WING (value changes, query replies).
    nonisolated let incoming: AsyncStream<WingIncoming>

    private let continuation: AsyncStream<WingIncoming>.Continuation
    private var socket: OSCUDPSocket?

    init(remotePort: UInt16 = WingNetwork.defaultPort) {
        self.remotePort = remotePort
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
        let socket = OSCUDPSocket(
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            interface: nil,
            isIPv4BroadcastEnabled: broadcast,
            isIPv6Enabled: false,
            queue: nil,
            receiveHandler: .messages { message, _, host, port in
                continuation.yield(
                    WingIncoming(
                        address: message.addressPattern.stringValue,
                        value: message.values.first.flatMap(WingValue.init(osc:)),
                        host: host,
                        port: port
                    )
                )
            }
        )
        try socket.start()
        self.socket = socket
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

    private func stopSocket() {
        socket?.stop()
        socket = nil
    }
}
