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
        // Nudge a stereo pair's two channels together, as if a live mix (or
        // another controller on the network) were in progress. Moving both
        // channels by the same delta keeps the pair's balance stable.
        let leftChannel = [1, 3, 5].randomElement() ?? 1
        let delta = Float.random(in: -0.04...0.04)
        for channel in [leftChannel, leftChannel + 1] {
            let address = WingAddress.fader(.channel, channel)
            let current = store[address]?.floatValue ?? FaderMath.unityPosition
            let next = min(max(current + delta, 0), 1)
            store[address] = .float(next)
            emit(address, .float(next))
        }
    }

    // MARK: - Seed data

    private func seed() {
        store = Self.seededStore()
    }

    /// The full seeded console state. Shared by the live simulator and by
    /// SwiftUI previews so both show the same believable WING.
    static func seededStore() -> [String: WingValue] {
        var store: [String: WingValue] = [:]
        for kind in [WingNodeKind.channel, .aux, .bus, .main, .matrix, .dca] {
            for index in 1...kind.count {
                store[WingAddress.name(kind, index)] = .string(seedName(kind, index))
                store[WingAddress.fader(kind, index)] = .float(seedPosition(kind, index))
                store[WingAddress.mute(kind, index)] = .int(0)
            }
        }
        // Seed channel input patches so the routing screens are populated too.
        for channel in 1...WingNodeKind.channel.count {
            let source = (channel <= WingSourceGroup.local.count)
                ? WingSource(group: .local, index: channel)
                : .none
            store[WingAddress.channelSourceGroup(channel)] = .string(source.group.rawValue)
            store[WingAddress.channelSourceIndex(channel)] = .int(Int32(source.index))
        }
        // Seed main assignments and a few bus sends so output routing looks live.
        for channel in 1...WingNodeKind.channel.count {
            store[WingAddress.mainOn(.channel, channel, toMain: 1)] = .int(1)
            for bus in 1...4 {
                let isOn = (channel % bus == 0)
                store[WingAddress.sendOn(.channel, channel, toBus: bus)] = .int(isOn ? 1 : 0)
                store[WingAddress.sendLevel(.channel, channel, toBus: bus)] = .float(-12)
            }
        }
        // Name buses 1–4 as the standard quad speakers so the spatial screens
        // look live offline.
        let speakerNames = ["Front L", "Front R", "Rear L", "Rear R"]
        for (offset, speakerName) in speakerNames.enumerated() {
            store[WingAddress.name(.bus, offset + 1)] = .string(speakerName)
        }
        // Hard-pan the stereo rig channels (L/R) and centre the mono ones so the
        // demo images correctly offline.
        for (channel, pan) in channelPans {
            store[WingAddress.pan(.channel, channel)] = .float(pan)
        }
        return store
    }

    private static func seedName(_ kind: WingNodeKind, _ index: Int) -> String {
        if kind == .channel, let name = channelNames[index] {
            return name
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

    /// Channel scribble names derived from the gear rig: a stereo device gets
    /// "<name> L" / "<name> R" across its two channels, a mono device a single
    /// "<name>". This keeps the demo in lock-step with the real channel layout.
    private static let channelNames: [Int: String] = {
        var names: [Int: String] = [:]
        for assignment in Equipment.channelAssignments() {
            if let right = assignment.rightChannel {
                names[assignment.leftChannel] = "\(assignment.equipment.name) L"
                names[right] = "\(assignment.equipment.name) R"
            } else {
                names[assignment.leftChannel] = assignment.equipment.name
            }
        }
        return names
    }()

    /// Pan seeds for the rig channels: stereo pairs hard-panned L/R, mono centred.
    private static let channelPans: [Int: Float] = {
        var pans: [Int: Float] = [:]
        for assignment in Equipment.channelAssignments() {
            if let right = assignment.rightChannel {
                pans[assignment.leftChannel] = -1
                pans[right] = 1
            } else {
                pans[assignment.leftChannel] = 0
            }
        }
        return pans
    }()

    private static let seedPositions: [Float] = [0.78, 0.72, 0.75, 0.68, 0.80, 0.74]
}
