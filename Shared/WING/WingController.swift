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
    private var refreshTask: Task<Void, Never>?

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

    /// A demo controller pre-populated with the seeded console, for SwiftUI
    /// previews. Synchronous: no transport is started and no tasks run.
    static func preview() -> WingController {
        let controller = WingController(demoTransport: DemoWingTransport())
        controller.connection = .connected(name: "Demo WING Rack")
        controller.values = DemoWingTransport.seededStore()
        return controller
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
            startBulkRefresh()
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

    /// Sets a strip's pan: `-1` hard left, `0` centre, `+1` hard right. The WING
    /// `/pan` value range is modelled as `-1...1`; to be re-verified against a
    /// real console during the smoke test.
    func setPan(_ kind: WingNodeKind, _ index: Int, pan: Float) async {
        await set(WingAddress.pan(kind, index), .float(min(max(pan, -1), 1)))
    }

    /// Maximum scribble-strip name length sent to the WING. The console caps
    /// scribble names, so longer strings are clamped before sending.
    static let maxNameLength = 12

    /// Writes a strip's scribble-strip `/name` back to the console, so the change
    /// is shared with the WING and every other client (including WING Co-Pilot).
    /// The name is trimmed and clamped to ``maxNameLength`` before sending.
    func setName(_ kind: WingNodeKind, _ index: Int, to name: String) async {
        await set(WingAddress.name(kind, index), .string(Self.sanitizeName(name)))
    }

    /// Writes a strip's `/col` colour index back to the console.
    ///
    /// - Note: The WING colour value type/range (palette index) is still to be
    ///   verified against real hardware; treat as provisional until confirmed.
    ///   The index is clamped to a non-negative `Int32` to avoid trapping on
    ///   out-of-range input.
    func setColor(_ kind: WingNodeKind, _ index: Int, to colorIndex: Int) async {
        await set(WingAddress.color(kind, index), .int(Int32(clamping: max(colorIndex, 0))))
    }

    /// Current colour index for a node, if known.
    func color(_ kind: WingNodeKind, _ index: Int) -> Int? {
        values[WingAddress.color(kind, index)]?.intValue.map(Int.init)
    }

    /// Trims whitespace and clamps a scribble-strip name to `maxLength`
    /// (defaulting to ``maxNameLength``).
    static func sanitizeName(_ name: String, maxLength: Int = maxNameLength) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxLength))
    }

    /// Re-queries a node so its cached value reflects the console (for example,
    /// after a change was made in the WING Co-Pilot app). The reply arrives on
    /// the incoming stream.
    func refresh(_ address: String) async {
        try? await transport.send(address)
    }

    /// Re-queries every relevant node so the cache reflects the console's
    /// current state — for example after connecting, or as a manual "Resync
    /// from console" action. Replies arrive on the incoming stream and populate
    /// `values`. Queries are paced in small batches to avoid flooding the
    /// console, and the loop honours cancellation so a disconnect mid-refresh
    /// tears down cleanly.
    func refreshAll() async {
        let addresses = WingAddress.allQueryAddresses()
        var batch: [String] = []
        batch.reserveCapacity(WingNetwork.bulkRefreshBatchSize)
        for address in addresses {
            if Task.isCancelled { return }
            batch.append(address)
            if batch.count >= WingNetwork.bulkRefreshBatchSize {
                await query(batch)
                batch.removeAll(keepingCapacity: true)
                try? await Task.sleep(for: WingNetwork.bulkRefreshBatchDelay)
            }
        }
        if Task.isCancelled { return }
        await query(batch)
    }

    /// Issues GET queries for a batch of addresses; replies arrive on the
    /// incoming stream and populate `values`.
    private func query(_ addresses: [String]) async {
        guard !addresses.isEmpty else { return }
        for address in addresses {
            if Task.isCancelled { return }
            try? await transport.send(address)
        }
    }

    /// Current fader value for a strip in decibels, if known.
    func faderDecibels(_ kind: WingNodeKind, _ index: Int) -> Float? {
        values[WingAddress.fader(kind, index)]?.floatValue.map(FaderMath.decibels(fromPosition:))
    }

    /// Current normalised fader position (`0.0...1.0`) for a strip, if known.
    func faderPosition(_ kind: WingNodeKind, _ index: Int) -> Float? {
        values[WingAddress.fader(kind, index)]?.floatValue
    }

    /// Current scribble-strip name for a node, if known.
    func name(_ kind: WingNodeKind, _ index: Int) -> String? {
        values[WingAddress.name(kind, index)]?.stringValue
    }

    /// Current mute state for a strip, if known.
    func isMuted(_ kind: WingNodeKind, _ index: Int) -> Bool? {
        values[WingAddress.mute(kind, index)]?.intValue.map { $0 != 0 }
    }

    /// Current pan for a strip (`-1...1`), if known.
    func pan(_ kind: WingNodeKind, _ index: Int) -> Float? {
        values[WingAddress.pan(kind, index)]?.floatValue
    }

    // MARK: - Stereo pairs

    /// Drives a ganged stereo pair from a single fader `position` (`0...1`) plus
    /// a `balance` trim (`-1` favours left … `0` even … `+1` favours right). The
    /// right node may be `nil`, in which case only the left node is set, so the
    /// same call works for mono strips.
    func setFaderPair(_ left: WingNodeRef, _ right: WingNodeRef?, position: Float, balance: Float = 0) async {
        await setFader(left.kind, left.index, position: position - balance / 2)
        if let right {
            await setFader(right.kind, right.index, position: position + balance / 2)
        }
    }

    /// Links the mute of a stereo pair (or just the left node when `right` is nil).
    func setMutePair(_ left: WingNodeRef, _ right: WingNodeRef?, muted: Bool) async {
        await setMute(left.kind, left.index, muted: muted)
        if let right {
            await setMute(right.kind, right.index, muted: muted)
        }
    }

    /// Hard-pans a stereo pair fully left and right so it images correctly.
    func hardPanPair(_ left: WingNodeRef, _ right: WingNodeRef?) async {
        await setPan(left.kind, left.index, pan: -1)
        if let right {
            await setPan(right.kind, right.index, pan: 1)
        }
    }

    /// Length of the ` L`/` R` suffix appended to each node of a stereo pair.
    private static let stereoSuffixLength = 2

    /// Renames a strip on the console. For a stereo pair the two nodes get the
    /// shared name with ` L`/` R` suffixes; a mono strip gets the name as-is. The
    /// base name is clamped to leave room for the suffix so both nodes stay
    /// distinct within ``maxNameLength``.
    func setNamePair(_ left: WingNodeRef, _ right: WingNodeRef?, to name: String) async {
        if let right {
            let base = Self.sanitizeName(name, maxLength: Self.maxNameLength - Self.stereoSuffixLength)
            await setName(left.kind, left.index, to: base + " L")
            await setName(right.kind, right.index, to: base + " R")
        } else {
            await setName(left.kind, left.index, to: name)
        }
    }

    // MARK: - Routing

    /// Patches a channel's input to the given source.
    func setChannelSource(_ channel: Int, to source: WingSource) async {
        await apply(source.settings(forChannel: channel))
    }

    /// The channel's currently patched input source, if known.
    func channelSource(_ channel: Int) -> WingSource? {
        guard let token = values[WingAddress.channelSourceGroup(channel)]?.stringValue,
              let group = WingSourceGroup(rawValue: token) else { return nil }
        let index = Int(values[WingAddress.channelSourceIndex(channel)]?.intValue ?? 0)
        return WingSource(group: group, index: index)
    }

    /// Assigns or unassigns a strip to a main bus.
    func setMainAssign(_ kind: WingNodeKind, _ index: Int, toMain main: Int, on enabled: Bool) async {
        await set(WingAddress.mainOn(kind, index, toMain: main), .int(enabled ? 1 : 0))
    }

    func isMainAssigned(_ kind: WingNodeKind, _ index: Int, toMain main: Int) -> Bool? {
        values[WingAddress.mainOn(kind, index, toMain: main)]?.intValue.map { $0 != 0 }
    }

    /// Turns a bus send on or off for a strip.
    func setSend(_ kind: WingNodeKind, _ index: Int, toBus bus: Int, on enabled: Bool) async {
        await set(WingAddress.sendOn(kind, index, toBus: bus), .int(enabled ? 1 : 0))
    }

    func isSendOn(_ kind: WingNodeKind, _ index: Int, toBus bus: Int) -> Bool? {
        values[WingAddress.sendOn(kind, index, toBus: bus)]?.intValue.map { $0 != 0 }
    }

    /// Sets a bus-send level in decibels.
    func setSendLevel(_ kind: WingNodeKind, _ index: Int, toBus bus: Int, decibels: Float) async {
        await set(WingAddress.sendLevel(kind, index, toBus: bus), .float(decibels))
    }

    func sendLevel(_ kind: WingNodeKind, _ index: Int, toBus bus: Int) -> Float? {
        values[WingAddress.sendLevel(kind, index, toBus: bus)]?.floatValue
    }

    // MARK: - Batch

    /// Applies a batch of settings to the WING. Used by presets and by the chain
    /// builder's "Apply" action.
    func apply(_ settings: [WingSetting]) async {
        for setting in settings {
            await set(setting.address, setting.value)
        }
    }

    /// Captures the current cached values for the given addresses as a snapshot,
    /// suitable for saving into a preset.
    func snapshot(of addresses: [String]) -> [WingSetting] {
        addresses.compactMap { address in
            values[address].map { WingSetting(address: address, value: $0) }
        }
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

    private func startBulkRefresh() {
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refreshAll()
        }
    }

    private func cancelTasks() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        listenTask?.cancel()
        listenTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}
