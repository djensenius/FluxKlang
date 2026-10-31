//
//  WingDiscovery.swift
//  FluxKlang
//
//  Finds WING consoles on the local network by broadcasting an OSC info request
//  and collecting the replies. Manual IP entry and a persisted last-known host
//  (see AppModel) act as fallbacks when broadcast discovery is unavailable.
//

import Darwin
import Foundation
import Observation

/// A WING console found on the network.
struct DiscoveredWing: Identifiable, Hashable, Sendable {
    var host: String
    var name: String
    var model: String?
    var identifier: String?
    var firmware: String?

    var id: String { host }
}

/// Pure parsing of WING info-request replies, kept separate from the networking
/// so it can be unit-tested without a console.
enum WingDiscoveryParser {
    /// Whether an OSC address is a reply to an info request.
    static func isInfoReply(_ address: String) -> Bool {
        if address == WingAddress.info || address == "/*" { return true }
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
        if strings.count == 1,
           strings[0].contains(","),
           let csvWing = wing(fromCSV: strings[0], fallbackHost: host) {
            return csvWing
        }
        let rawName = strings.count > 1 ? strings[1] : (strings.first ?? host)
        let name = rawName.isEmpty ? host : rawName
        let model = strings.count > 2 ? strings[2] : nil
        let firmware = strings.count > 3 ? strings[3] : nil
        return DiscoveredWing(
            host: host,
            name: name,
            model: nonEmpty(model),
            identifier: nil,
            firmware: nonEmpty(firmware)
        )
    }

    private static func wing(fromCSV payload: String, fallbackHost: String) -> DiscoveredWing? {
        let fields = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.first?.uppercased() == "WING" else { return nil }
        let reportedHost = fields.indices.contains(1) ? fields[1] : ""
        let name = fields.indices.contains(2) ? fields[2] : ""
        let model = fields.indices.contains(3) ? displayModel(fields[3]) : nil
        let identifier = fields.indices.contains(4) ? fields[4] : nil
        let firmware = fields.indices.contains(5) ? fields[5] : nil
        return DiscoveredWing(
            host: fallbackHost.isEmpty ? reportedHost : fallbackHost,
            name: name.isEmpty ? (reportedHost.isEmpty ? fallbackHost : reportedHost) : name,
            model: nonEmpty(model),
            identifier: nonEmpty(identifier),
            firmware: nonEmpty(firmware)
        )
    }

    private static func displayModel(_ token: String) -> String {
        token
            .split(separator: "-")
            .map { part in
                part.caseInsensitiveCompare("wing") == .orderedSame
                    ? "WING"
                    : part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
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

    /// Why the last scan could not search, so an empty result isn't mistaken for "no consoles".
    private(set) var unavailableReason: String?

    private let port: UInt16
    private let broadcastPermission: PermissionState

    init(port: UInt16 = WingNetwork.defaultPort,
         broadcastPermission: PermissionState = LocalNetworkAccess.currentBroadcastDiscovery) {
        self.port = port
        self.broadcastPermission = broadcastPermission
    }

    /// Broadcasts an info request and collects responders for `duration`.
    func scan(duration: Duration = .seconds(3)) async {
        guard !isScanning else { return }
        responders = []
        unavailableReason = nil
        // iOS blocks broadcast without the Apple-gated multicast entitlement; don't send at all.
        guard broadcastPermission.status != .unsupported else {
            unavailableReason = broadcastPermission.reason
            return
        }
        isScanning = true

        let broadcastHosts = Self.activeIPv4BroadcastHosts()
        guard let firstBroadcastHost = broadcastHosts.first else {
            unavailableReason = "No Wi-Fi or Ethernet network is active. "
                + "Join the WING's network or enter its IP address."
            isScanning = false
            return
        }
        let transport = WingTransport(remotePort: port)
        do {
            try await transport.start(remoteHost: firstBroadcastHost, localPort: port, broadcast: true)
        } catch {
            unavailableReason = "Couldn't start a network scan (\(error.localizedDescription)). "
                + "Enter the WING's IP address instead."
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

        var sent = 0, sendErrnos: [Int32?] = []
        for host in broadcastHosts {
            do {
                try await transport.send(WingAddress.info, nil, to: host, port: port)
                sent += 1
            } catch {
                sendErrnos.append(LocalNetworkAccess.errno(in: error))
            }
        }
        if sent == 0 {
            let code = LocalNetworkAccess.dominantErrno(sendErrnos)
            unavailableReason = LocalNetworkAccess.discoveryFailureReason(errno: code)
        } else {
            try? await Task.sleep(for: duration)
        }

        listen.cancel()
        await transport.stop()
        isScanning = false
    }

    private static func activeIPv4BroadcastHosts() -> [String] {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let firstInterface = interfaceList else {
            return []
        }
        defer { freeifaddrs(firstInterface) }

        var hosts: Set<String> = []
        var interface: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = interface {
            defer { interface = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_BROADCAST) != 0,
                  let address = current.pointee.ifa_dstaddr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let host = String(bytes: bytes, encoding: .utf8) else { continue }
            hosts.insert(host)
        }
        return hosts.sorted()
    }

    private func add(_ wing: DiscoveredWing) {
        guard !responders.contains(where: { $0.host == wing.host }) else { return }
        responders.append(wing)
    }
}
