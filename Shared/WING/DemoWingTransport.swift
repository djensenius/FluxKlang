//
//  DemoWingTransport.swift
//  FluxKlang
//
//  An in-memory WING simulator that powers Demo Mode. It lets the full app be
//  explored offline — when you're off the network and just want to sample how
//  things work. It mimics a real WING Rack: it seeds a believable console
//  (channels named after real gear), answers queries from its store, echoes
//  every SET back the way the console broadcasts changes to all clients, and
//  emits gentle ambient fader moves to simulate a live mix or another operator
//  (e.g. the WING Co-Pilot app) on the network.
//

import Foundation

actor DemoWingTransport: WingTransporting {
    nonisolated let incoming: AsyncStream<WingIncoming>

    private let continuation: AsyncStream<WingIncoming>.Continuation
    private var store: [String: WingValue] = [:]
    private var ambientTask: Task<Void, Never>?

    private static let demoHost = "demo.local"

    init() {
        (incoming, continuation) = AsyncStream.makeStream(of: WingIncoming.self)
    }

    deinit {
        ambientTask?.cancel()
        continuation.finish()
    }

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) {
        seed()
        emitAll()
        startAmbient()
    }

    func stop() {
        ambientTask?.cancel()
        ambientTask = nil
    }

    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) {
        // Ignore console-level commands (subscribe / info request).
        guard address != WingAddress.subscribe, address != WingAddress.info else { return }
        if let value {
            // SET: update the store and echo it back, as the console broadcasts
            // changes to every connected client.
            store[address] = value
            emit(address, value)
        } else if let existing = store[address] {
            // GET: reply with the current value on the incoming stream.
            emit(address, existing)
        }
    }

    // MARK: - Simulation

    private func emit(_ address: String, _ value: WingValue) {
        continuation.yield(
            WingIncoming(address: address, value: value, host: Self.demoHost, port: WingNetwork.defaultPort)
        )
    }

    private func emitAll() {
        for (address, value) in store {
            emit(address, value)
        }
    }

    private func startAmbient() {
        ambientTask?.cancel()
        ambientTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2500))
                guard let self else { return }
                await self.ambientTick()
            }
        }
    }

    private func ambientTick() async {
        // Nudge one of the first few channel faders a little, as if a live mix
        // (or another controller on the network) were in progress.
        let channel = Int.random(in: 1...6)
        let address = WingAddress.fader(.channel, channel)
        let current = store[address]?.floatValue ?? FaderMath.unityPosition
        let next = min(max(current + Float.random(in: -0.04...0.04), 0), 1)
        store[address] = .float(next)
        emit(address, .float(next))
    }

    // MARK: - Seed data

    private func seed() {
        store.removeAll(keepingCapacity: true)
        for kind in [WingNodeKind.channel, .aux, .bus, .main, .matrix, .dca] {
            for index in 1...kind.count {
                store[WingAddress.name(kind, index)] = .string(Self.seedName(kind, index))
                store[WingAddress.fader(kind, index)] = .float(Self.seedPosition(kind, index))
                store[WingAddress.mute(kind, index)] = .int(0)
            }
        }
        // Seed channel input patches so the routing screens are populated too.
        for channel in 1...WingNodeKind.channel.count {
            store[WingAddress.channelSourceGroup(channel)] = .int(0)
            store[WingAddress.channelSourceIndex(channel)] = .int(Int32(channel))
        }
    }

    private static func seedName(_ kind: WingNodeKind, _ index: Int) -> String {
        if kind == .channel, index <= channelNames.count {
            return channelNames[index - 1]
        }
        if kind == .main, index == 1 {
            return "Main LR"
        }
        return "\(kind.label) \(index)"
    }

    private static func seedPosition(_ kind: WingNodeKind, _ index: Int) -> Float {
        switch kind {
        case .channel: return seedPositions[(index - 1) % seedPositions.count]
        default: return FaderMath.unityPosition
        }
    }

    /// Channels 1–16 are named after the user's gear so the demo feels real.
    private static let channelNames = [
        "OP-1 Field", "OP-XY", "TX-6", "TP-7", "CM-15",
        "Torso S-4", "SOLAR 42F", "EviL Pet", "Cosmos", "Ether",
        "Flux", "Pipe", "OXI One", "OXI E16", "Buchla Ziggy",
        "Microcosm"
    ]

    private static let seedPositions: [Float] = [0.78, 0.72, 0.75, 0.68, 0.80, 0.74]
}
