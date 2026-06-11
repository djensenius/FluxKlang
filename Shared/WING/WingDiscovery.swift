//
//  WingDiscovery.swift
//  FluxKlang
//
//  Finds WING consoles on the local network by broadcasting an OSC info request
//  and collecting the replies. Manual IP entry and a persisted last-known host
//  (see AppModel) act as fallbacks when broadcast discovery is unavailable.
//

import Foundation
import Observation

/// A WING console found on the network.
struct DiscoveredWing: Identifiable, Hashable, Sendable {
    var host: String
    var name: String
    var model: String?

    var id: String { host }
}

/// Pure parsing of WING info-request replies, kept separate from the networking
/// so it can be unit-tested without a console.
enum WingDiscoveryParser {
    /// Whether an OSC address is a reply to an info request.
    static func isInfoReply(_ address: String) -> Bool {
        if address == WingAddress.info { return true }
        let lowered = address.lowercased()
        return lowered.hasPrefix("/?") || lowered.contains("info")
    }

    /// Parses an info reply into a `DiscoveredWing`. The WING answers an info
    /// request with descriptive strings following the X-series convention
    /// (roughly `[version, name, model, firmware]`); the second string is the
    /// console name and the third its model. Falls back to the sender host when
    /// no name is provided.
    static func wing(fromReplyAt address: String, arguments: [WingValue], host: String) -> DiscoveredWing? {
        guard isInfoReply(address) else { return nil }
        let strings = arguments.compactMap(\.stringValue)
        let rawName = strings.count > 1 ? strings[1] : (strings.first ?? host)
        let name = rawName.isEmpty ? host : rawName
        let model = strings.count > 2 ? strings[2] : nil
        return DiscoveredWing(host: host, name: name, model: (model?.isEmpty == true) ? nil : model)
    }
}

/// Observable network scanner that broadcasts an info request and collects WING
/// responders.
@MainActor
@Observable
final class WingDiscovery {
    /// Consoles found during the most recent (or in-progress) scan.
    private(set) var responders: [DiscoveredWing] = []

    /// Whether a scan is currently running.
    private(set) var isScanning = false

    private let port: UInt16

    /// The limited-broadcast address; reaches every host on the local segment.
    private let broadcastHost = "255.255.255.255"

    init(port: UInt16 = WingNetwork.defaultPort) {
        self.port = port
    }

    /// Broadcasts an info request and collects responders for `duration`.
    func scan(duration: Duration = .seconds(3)) async {
        guard !isScanning else { return }
        isScanning = true
        responders = []

        let transport = WingTransport(remotePort: port)
        do {
            try await transport.start(remoteHost: broadcastHost, localPort: port, broadcast: true)
        } catch {
            isScanning = false
            return
        }

        let incoming = transport.incoming
        let listen = Task { @MainActor [weak self] in
            for await message in incoming {
                guard let self else { break }
                if let wing = WingDiscoveryParser.wing(
                    fromReplyAt: message.address,
                    arguments: message.values,
                    host: message.host
                ) {
                    add(wing)
                }
            }
        }

        try? await transport.send(WingAddress.info, nil, to: broadcastHost, port: port)
        try? await Task.sleep(for: duration)

        listen.cancel()
        await transport.stop()
        isScanning = false
    }

    private func add(_ wing: DiscoveredWing) {
        guard !responders.contains(where: { $0.host == wing.host }) else { return }
        responders.append(wing)
    }
}
