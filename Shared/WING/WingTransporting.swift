//
//  WingTransporting.swift
//  FluxKlang
//
//  Abstraction over the WING OSC transport so the controller can run against
//  either a real console (WingTransport) or the offline simulator used by Demo
//  Mode (DemoWingTransport). Both are actors that surface incoming messages as
//  an AsyncStream, so the controller code path is identical in either mode.
//

import Foundation

/// A transport capable of exchanging OSC messages with a WING, real or simulated.
protocol WingTransporting: Sendable {
    /// Stream of messages received from the WING (value changes, query replies).
    nonisolated var incoming: AsyncStream<WingIncoming> { get }

    /// Opens the transport and begins receiving. `broadcast` enables IPv4
    /// broadcast on the local port for discovery.
    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) async throws

    /// Closes the transport and stops receiving.
    func stop() async

    /// Sends an OSC message. A `nil` value sends the address with no arguments,
    /// which the WING treats as a query (GET) and answers on the incoming stream.
    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) async throws
}

extension WingTransporting {
    /// Convenience send to the default destination.
    func send(_ address: String, _ value: WingValue? = nil) async throws {
        try await send(address, value, to: nil, port: nil)
    }
}
