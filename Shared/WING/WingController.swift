//
//  WingController.swift
//  FluxKlang
//
//  High-level, observable controller for a WING Rack. Owns the transport,
//  drives the subscription keep-alive, and keeps a live cache of node values.
//
//  Because the WING is multi-client, this controller treats the console as the
//  source of truth: it ingests broadcast updates (including changes made in the
//  WING Co-Pilot app) and can re-query nodes on demand to stay in sync.
//

import Foundation
import Observation

/// Whether the controller talks to a real WING or the offline demo simulator.
enum WingMode: Sendable, Equatable {
    case live
    case demo
}

@MainActor
@Observable
final class WingController {
    /// Whether this controller is live or running in offline Demo Mode.
    let mode: WingMode

    /// Current connection state.
    private(set) var connection: WingConnectionState = .disconnected

    /// Last-known values keyed by OSC address. Reflects changes from any
    /// controller on the network, including the WING Co-Pilot app.
    private(set) var values: [String: WingValue] = [:]

    /// Host the controller is connected (or connecting) to.
    private(set) var host: String?

    /// The WING OSC port in use.
    let port: UInt16

    /// Whether this controller is running in offline Demo Mode.
    var isDemo: Bool { mode == .demo }

    private let transport: any WingTransporting
    private var listenTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    /// Creates a live controller that talks to a real WING over OSC/UDP.
    init(port: UInt16 = WingNetwork.defaultPort) {
        mode = .live
        self.port = port
        transport = WingTransport(remotePort: port)
    }

    private init(demoTransport: DemoWingTransport) {
        mode = .demo
        port = WingNetwork.defaultPort
        transport = demoTransport
    }

    /// Creates a controller backed by the offline demo simulator, for exploring
    /// the app without a WING on the network.
    static func demo() -> WingController {
        WingController(demoTransport: DemoWingTransport())
    }

    // MARK: - Lifecycle

    /// Connects to a WING at `host`, starts listening for updates, and begins
    /// the subscription keep-alive. In Demo Mode `host` is ignored and the
    /// offline simulator is used instead.
    func connect(host: String) async {
        guard connection != .connecting else { return }
        cancelTasks()
        connection = .connecting
        do {
            try await transport.start(remoteHost: host, localPort: nil, broadcast: false)
            self.host = isDemo ? nil : host
            connection = .connected(name: isDemo ? "Demo WING Rack" : nil)
            startListening()
            startKeepAlive()
        } catch {
            connection = .failed(reason: error.localizedDescription)
        }
    }

    /// Convenience entry point for Demo Mode that needs no host.
    func connectDemo() async {
        await connect(host: "demo")
    }

    /// Disconnects and tears down the keep-alive and listener.
    func disconnect() async {
        cancelTasks()
        await transport.stop()
        host = nil
        connection = .disconnected
    }

    // MARK: - Control

    /// Sets a fader by decibels, converted to the WING fader law.
    func setFader(_ kind: WingNodeKind, _ index: Int, decibels: Float) async {
        await set(WingAddress.fader(kind, index), .float(FaderMath.position(fromDecibels: decibels)))
    }

    /// Sets a fader by normalised position (`0.0...1.0`).
    func setFader(_ kind: WingNodeKind, _ index: Int, position: Float) async {
        await set(WingAddress.fader(kind, index), .float(min(max(position, 0), 1)))
    }

    /// Mutes or unmutes a strip.
    func setMute(_ kind: WingNodeKind, _ index: Int, muted: Bool) async {
        await set(WingAddress.mute(kind, index), .int(muted ? 1 : 0))
    }

    /// Re-queries a node so its cached value reflects the console (for example,
    /// after a change was made in the WING Co-Pilot app). The reply arrives on
    /// the incoming stream.
    func refresh(_ address: String) async {
        try? await transport.send(address)
    }

    /// Current fader value for a strip in decibels, if known.
    func faderDecibels(_ kind: WingNodeKind, _ index: Int) -> Float? {
        values[WingAddress.fader(kind, index)]?.floatValue.map(FaderMath.decibels(fromPosition:))
    }

    /// Current mute state for a strip, if known.
    func isMuted(_ kind: WingNodeKind, _ index: Int) -> Bool? {
        values[WingAddress.mute(kind, index)]?.intValue.map { $0 != 0 }
    }

    // MARK: - Private

    private func set(_ address: String, _ value: WingValue) async {
        try? await transport.send(address, value)
        values[address] = value
    }

    private func startListening() {
        let incoming = transport.incoming
        listenTask = Task { [weak self] in
            for await message in incoming {
                guard let self else { break }
                ingest(message)
            }
        }
    }

    private func ingest(_ message: WingIncoming) {
        guard let value = message.value else { return }
        values[message.address] = value
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await sendSubscribe()
                try? await Task.sleep(for: WingNetwork.subscriptionRenewInterval)
            }
        }
    }

    private func sendSubscribe() async {
        try? await transport.send(WingAddress.subscribe)
    }

    private func cancelTasks() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        listenTask?.cancel()
        listenTask = nil
    }
}
