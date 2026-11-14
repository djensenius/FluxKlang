//
//  WingDiscoveryTests.swift
//  FluxKlangTests
//

import Darwin
import Foundation
import Synchronization
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
struct WingDiscoveryTests {
    @Test func directInterfaceEnumerationIsDeniedBeforeAPIAccess() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        #expect(WingDiscovery.activeIPv4BroadcastHosts(mirroring: audit).isEmpty)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .discoveryInterfaces) == 1)
        #expect(snapshot.count(.denied, for: .discoveryInterfaces) == 1)
        #expect(snapshot.count(.apiEntered, for: .discoveryInterfaces) == 0)
    }

    @Test func recognisesInfoReplyAddresses() {
        #expect(WingDiscoveryParser.isInfoReply("/?"))
        #expect(WingDiscoveryParser.isInfoReply("/*"))
        #expect(WingDiscoveryParser.isInfoReply("/info"))
        #expect(WingDiscoveryParser.isInfoReply("/xinfo"))
        #expect(!WingDiscoveryParser.isInfoReply("/ch/1/fdr"))
    }

    @Test func parsesNameAndModelFromReply() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/?",
            arguments: [.string("V3.0.0"), .string("Studio WING"), .string("WING Rack"), .string("1.16")],
            host: "192.168.1.40"
        )
        #expect(wing?.host == "192.168.1.40")
        #expect(wing?.name == "Studio WING")
        #expect(wing?.model == "WING Rack")
        #expect(wing?.firmware == "1.16")
    }

    @Test func parsesHardwareCSVIdentityReply() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/*",
            arguments: [
                .string("WING,192.168.11.221,WING-PP-07111644,wing-rack,0100QL80604AAE,3.1-0-g9f314617:release")
            ],
            host: "192.168.11.221"
        )

        #expect(wing?.host == "192.168.11.221")
        #expect(wing?.name == "WING-PP-07111644")
        #expect(wing?.model == "WING Rack")
        #expect(wing?.identifier == "0100QL80604AAE")
        #expect(wing?.firmware == "3.1-0-g9f314617:release")
    }

    @Test func fallsBackToHostWhenNoName() {
        let wing = WingDiscoveryParser.wing(fromReplyAt: "/info", arguments: [], host: "10.0.0.5")
        #expect(wing?.name == "10.0.0.5")
        #expect(wing?.model == nil)
    }

    @Test func nonWingCommaPayloadFallsBackToLegacyParsing() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/info",
            arguments: [.string("Legacy Console, Studio A")],
            host: "10.0.0.6"
        )

        #expect(wing?.host == "10.0.0.6")
        #expect(wing?.name == "Legacy Console, Studio A")
    }

    @Test func ignoresNonInfoReplies() {
        let wing = WingDiscoveryParser.wing(
            fromReplyAt: "/ch/1/fdr",
            arguments: [.float(0.75)],
            host: "10.0.0.5"
        )
        #expect(wing == nil)
    }
}

@MainActor
extension WingDiscoveryTests {
    private static let allowed = PermissionState(capability: .multicast, status: .unknown)
    private static let noInterfacesReason = "No Wi-Fi or Ethernet network is active. "
        + "Join the WING's network or enter its IP address."

    @Test func unsupportedPermissionNeverEnumeratesOrMakesTransport() async {
        let permission = PermissionState(capability: .multicast, status: .unsupported)
        let discovery = WingDiscovery(broadcastPermission: permission, hardware: Self.poisonedFactories)

        #expect(!discovery.isScanning)
        #expect(discovery.unavailableReason == nil)
        await discovery.scan(duration: .zero)

        #expect(discovery.unavailableReason == permission.reason)
        #expect(discovery.responders.isEmpty)
        #expect(!discovery.isScanning)
    }

    @Test func emptyInterfacesNeverMakeTransport() async {
        let calls = DiscoveryCalls()
        var hardware = Self.poisonedFactories
        hardware.wingDiscoveryBroadcastHosts = {
            calls.record(.enumerate)
            return []
        }
        let discovery = WingDiscovery(broadcastPermission: Self.allowed, hardware: hardware)
        #expect(calls.events.isEmpty, "Construction must not enumerate interfaces")

        await discovery.scan(duration: .zero)

        #expect(calls.events == [.enumerate])
        #expect(discovery.unavailableReason == Self.noInterfacesReason)
        #expect(!discovery.isScanning)
        #expect(discovery.responders.isEmpty)
    }

    @Test func isolatedAndDefaultDiscoveryNeverEvaluateProductionDependencies() async throws {
        // Fail closed rather than risk a live default scan outside an isolated test host.
        try #require(AppPersistence.isTesting)
        let selected = HardwareServiceFactories.select(
            isTesting: true,
            production: {
                Issue.record("Isolated selection evaluated production dependencies")
                return Self.poisonedFactories
            }()
        )
        var defaults = HardwareServiceFactories(makeLaunchControlXLInput: { InertLaunchControlXLInput() })
        defaults.makeWingTransport = Self.poisonedFactories.makeWingTransport
        defaults.localNetworkProbe = Self.poisonedFactories.localNetworkProbe
        let discoveries = [
            WingDiscovery(broadcastPermission: Self.allowed, hardware: selected),
            WingDiscovery(broadcastPermission: Self.allowed, hardware: defaults),
            WingDiscovery(broadcastPermission: Self.allowed, hardware: .inert),
            WingDiscovery(broadcastPermission: Self.allowed)
        ]

        for discovery in discoveries {
            await discovery.scan(duration: .zero)
            #expect(discovery.unavailableReason == Self.noInterfacesReason)
            #expect(discovery.responders.isEmpty)
            #expect(!discovery.isScanning)
        }
    }

    @Test func explicitFakeScanLazilyStartsFirstHostQueriesAllHostsAndStops() async {
        let calls = DiscoveryCalls()
        let hosts = ["192.0.2.255", "198.51.100.255"]
        let hardware = HardwareServiceFactories.select(
            isTesting: false, production: Self.factories(hosts: hosts, calls: calls)
        )
        let discovery = WingDiscovery(port: 9000, broadcastPermission: Self.allowed, hardware: hardware)
        #expect(calls.events.isEmpty, "Selection and construction must leave both providers unevaluated")

        await discovery.scan(duration: .zero)

        #expect(calls.events == [
            .enumerate, .makeTransport(9000), .start(hosts[0], 9000, true),
            .send(WingAddress.info, false, hosts[0], 9000),
            .send(WingAddress.info, false, hosts[1], 9000), .stop
        ])
        #expect(discovery.unavailableReason == nil)
        #expect(discovery.responders.isEmpty)
        #expect(!discovery.isScanning)
    }

    @Test func fakeStartFailureExplainsFailureWithoutSending() async {
        let calls = DiscoveryCalls()
        let host = "192.0.2.255"
        let hardware = Self.factories(hosts: [host], calls: calls, failsStart: true)
        let discovery = WingDiscovery(broadcastPermission: Self.allowed, hardware: hardware)

        await discovery.scan(duration: .zero)

        #expect(calls.events == [
            .enumerate, .makeTransport(WingNetwork.defaultPort),
            .start(host, WingNetwork.defaultPort, true)
        ])
        let detail = WingTransportError.notStarted.localizedDescription
        #expect(discovery.unavailableReason == "Couldn't start a network scan (\(detail)). "
            + "Enter the WING's IP address instead.")
        #expect(!discovery.isScanning)
        #expect(discovery.responders.isEmpty)
    }

    @Test(arguments: [
        [ENETUNREACH, EACCES], [EACCES, ENETUNREACH], [ENETDOWN, ENETUNREACH], [EIO, EIO]
    ])
    func failedFakeSendsExplainDominantErrorAndStop(codes: [Int32]) async {
        let calls = DiscoveryCalls()
        let hosts = ["192.0.2.255", "198.51.100.255"]
        let hardware = Self.factories(
            hosts: hosts, calls: calls, sendErrnos: Dictionary(uniqueKeysWithValues: zip(hosts, codes))
        )
        let discovery = WingDiscovery(port: 9001, broadcastPermission: Self.allowed, hardware: hardware)

        await discovery.scan(duration: .zero)

        #expect(calls.events == [
            .enumerate, .makeTransport(9001), .start(hosts[0], 9001, true),
            .send(WingAddress.info, false, hosts[0], 9001),
            .send(WingAddress.info, false, hosts[1], 9001), .stop
        ])
        let dominant = LocalNetworkAccess.dominantErrno(codes.map { Optional($0) })
        #expect(discovery.unavailableReason == LocalNetworkAccess.discoveryFailureReason(errno: dominant))
        #expect(!discovery.isScanning)
        #expect(discovery.responders.isEmpty)
    }

    @Test func partialFakeSendSuccessDoesNotReportScanUnavailable() async {
        let calls = DiscoveryCalls()
        let hosts = ["192.0.2.255", "198.51.100.255"]
        let hardware = Self.factories(hosts: hosts, calls: calls, sendErrnos: [hosts[0]: EACCES])
        let discovery = WingDiscovery(port: 9002, broadcastPermission: Self.allowed, hardware: hardware)

        await discovery.scan(duration: .zero)

        #expect(calls.events == [
            .enumerate, .makeTransport(9002), .start(hosts[0], 9002, true),
            .send(WingAddress.info, false, hosts[0], 9002),
            .send(WingAddress.info, false, hosts[1], 9002), .stop
        ])
        #expect(discovery.unavailableReason == nil)
        #expect(!discovery.isScanning)
    }

    private static var poisonedFactories: HardwareServiceFactories {
        var hardware = HardwareServiceFactories.inert
        hardware.wingDiscoveryBroadcastHosts = {
            Issue.record("Unexpected interface enumeration")
            return []
        }
        hardware.makeWingTransport = { _, _ in
            Issue.record("Unexpected transport construction")
            return InertWingTransport()
        }
        hardware.localNetworkProbe = { _, _ in
            Issue.record("Discovery must not perform a Local Network probe")
            return ENETUNREACH
        }
        return hardware
    }

    private static func factories(
        hosts: [String], calls: DiscoveryCalls, failsStart: Bool = false, sendErrnos: [String: Int32] = [:]
    ) -> HardwareServiceFactories {
        var hardware = poisonedFactories
        hardware.wingDiscoveryBroadcastHosts = {
            calls.record(.enumerate)
            return hosts
        }
        hardware.makeWingTransport = { port, _ in
            calls.record(.makeTransport(port))
            return RecordingDiscoveryTransport(calls: calls, failsStart: failsStart, sendErrnos: sendErrnos)
        }
        return hardware
    }
}

private final class DiscoveryCalls: Sendable {
    enum Event: Equatable, Sendable {
        case enumerate
        case makeTransport(UInt16)
        case start(String, UInt16?, Bool)
        case send(String, Bool, String?, UInt16?)
        case stop
    }

    private let recorded = Mutex<[Event]>([])
    var events: [Event] { recorded.withLock { $0 } }

    func record(_ event: Event) {
        recorded.withLock { $0.append(event) }
    }
}

/// A finished stream and mutex-backed calls only; no socket, resolver, or probe.
private struct RecordingDiscoveryTransport: WingTransporting {
    let calls: DiscoveryCalls
    let failsStart: Bool
    let sendErrnos: [String: Int32]
    let incoming = AsyncStream<WingIncoming> { $0.finish() }

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) async throws {
        calls.record(.start(remoteHost, localPort, broadcast))
        if failsStart { throw WingTransportError.notStarted }
    }

    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) async throws {
        calls.record(.send(address, value != nil, host, port))
        if let host, let code = sendErrnos[host] {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    func stop() async {
        calls.record(.stop)
    }
}
