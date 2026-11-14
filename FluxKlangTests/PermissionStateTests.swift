//
//  PermissionStateTests.swift
//  FluxKlangTests
//
//  Truthful permission states, prompt-free startup gating, and Local Network
//  denial reporting for the manual-IP WING path. No test opens a socket,
//  sends traffic, or queries/requests a system permission.
//

import Darwin
import Foundation
import Synchronization
import Testing
@testable import FluxKlang

/// Mirrors NIOCore.IOError: `private enum Error { case errno(CInt) }; private let error: Error`.
private struct NIOStyleIOError: Error {
    enum Code { case errno(Int32) }
    let error: Code
    init(errnoCode: Int32) { error = .errno(errnoCode) }
}

private struct Wrapped: Error { let underlying: any Error }

@MainActor
@Suite(.serialized, .productionAccessAudit)
struct PermissionStateTests {
    private static let host = "192.0.2.10"

    @Test func literalAndMalformedPeerInputsNeverAttemptDNS() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        #expect(WingPeerIdentity.ipv4Addresses(for: Self.host, mirroring: audit) == [Self.host])
        for host in ["", "invalid host", "192.0.2.10\n", "192.0.2.10\u{0}ignored"] {
            #expect(WingPeerIdentity.ipv4Addresses(for: host, mirroring: audit).isEmpty)
        }
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .wingPeerResolution) == 0)
        #expect(snapshot.count(.denied, for: .wingPeerResolution) == 0)
        #expect(snapshot.count(.apiEntered, for: .wingPeerResolution) == 0)
    }

    @Test func isolatedHostnameResolutionDoesNotEnterDNS() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        #expect(WingPeerIdentity.ipv4Addresses(for: "must-not-resolve.invalid", mirroring: audit).isEmpty)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .wingPeerResolution) == 1)
        #expect(snapshot.count(.denied, for: .wingPeerResolution) == 1)
        #expect(snapshot.count(.apiEntered, for: .wingPeerResolution) == 0)
    }

    @Test func isolatedUDPProbeRefusesBeforeAnySocketAPI() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        #expect(LocalNetworkProbe.connectErrno(
            ipv4: Self.host, port: WingNetwork.defaultPort, mirroring: audit) == ENETUNREACH)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .localNetworkProbe) == 1)
        #expect(snapshot.count(.denied, for: .localNetworkProbe) == 1)
        #expect(snapshot.count(.apiEntered, for: .localNetworkProbe) == 0)
    }

    @Test func onlyGrantedStatesAreUsableAndNoStateClaimsMoreThanIsKnown() {
        #expect(PermissionState(capability: .microphone, status: .granted).isUsable)
        let statuses: [PermissionStatus] = [.notDetermined, .denied, .possiblyDenied, .unreachable,
                                            .restricted, .unknown, .unsupported]
        for status in statuses {
            for capability in PermissionCapability.allCases {
                let state = PermissionState(capability: capability, status: status)
                #expect(!state.isUsable)
                #expect(!state.reason.contains("allowed."), "\(capability) \(status) must not claim access")
            }
        }
        let possible = PermissionState(capability: .localNetwork, status: .possiblyDenied).reason
        #expect(possible.contains("may be off") && possible.contains("WING's network"))
        #expect(!PermissionState(capability: .localNetwork, status: .unreachable).reason.contains("Local Network"))
    }

    @Test func connectErrnoNeverInfersAConfirmedDenial() {
        #expect(LocalNetworkAccess.status(afterConnectErrno: nil) == .granted)
        #expect(LocalNetworkAccess.status(afterConnectErrno: ENETUNREACH) == .unreachable)
        for code in [EHOSTUNREACH, EPERM, EACCES] {
            #expect(LocalNetworkAccess.status(afterConnectErrno: code) == .possiblyDenied)
        }
        #expect(LocalNetworkAccess.status(afterConnectErrno: ECONNREFUSED) == .unknown)
    }

    @Test func probeFailureWordingNamesEveryPlausibleCause() {
        let settings = LocalNetworkAccess.settingsPath
        #if os(macOS)
        #expect(settings == "System Settings › Privacy & Security › Local Network")
        #else
        #expect(settings == "Settings › Privacy & Security › Local Network")
        #endif
        #expect(LocalNetworkAccess.connectFailureReason(errno: ENETUNREACH, host: Self.host)
            == "This device isn't connected to a network that can reach 192.0.2.10. "
            + "Join the WING's network and try again.")
        let possible = "Can't reach 192.0.2.10. Check that this device is on the WING's network. If it is, "
            + "Local Network access may be off for FluxKlang: allow it in \(settings), then try again."
        #expect(LocalNetworkAccess.connectFailureReason(errno: EHOSTUNREACH, host: Self.host) == possible)
        #expect(LocalNetworkAccess.connectFailureReason(errno: EACCES, host: Self.host) == possible)
    }

    @Test func discoveryDenialGuidanceNeverOffersTheManualIPBypass() {
        let possible = LocalNetworkAccess.discoveryFailureReason(errno: EHOSTUNREACH)
        #expect(possible == "The scan couldn't send. Check that this device is on the WING's network. If it is, "
            + "Local Network access may be off for FluxKlang: allow it in \(LocalNetworkAccess.settingsPath), "
            + "then scan again.")
        for code in [EHOSTUNREACH, EPERM, EACCES, ENETUNREACH] {
            let reason = LocalNetworkAccess.discoveryFailureReason(errno: code)
            #expect(!reason.contains("IP address"), "errno \(code) must not suggest manual IP")
        }
        let noRoute = LocalNetworkAccess.discoveryFailureReason(errno: ENETUNREACH)
        #expect(noRoute.contains("Join the WING's network") && !noRoute.contains("Local Network"))
        #expect(LocalNetworkAccess.discoveryFailureReason(errno: nil).contains("enter the WING's IP address"))
        #expect(LocalNetworkAccess.discoveryFailureReason(errno: ECONNREFUSED).contains("IP address"))
    }

    @Test func discoveryGuidanceDoesNotDependOnInterfaceOrder() {
        let status = { (codes: [Int32?]) in
            LocalNetworkAccess.dominantErrno(codes).map(LocalNetworkAccess.status(afterConnectErrno:))
        }
        for codes: [Int32?] in [[ECONNREFUSED, EHOSTUNREACH], [nil, ENETUNREACH, EPERM], [EPERM, ECONNREFUSED]] {
            #expect(status(codes) == .possiblyDenied)
            #expect(status(codes.reversed()) == .possiblyDenied)
        }
        #expect(LocalNetworkAccess.dominantErrno([ECONNREFUSED, ENETUNREACH]) == ENETUNREACH)
        #expect(LocalNetworkAccess.dominantErrno([nil, ECONNREFUSED]) == ECONNREFUSED)
        #expect(LocalNetworkAccess.dominantErrno([nil, nil]) == nil)
    }

    @Test func socketErrorsYieldTheirErrno() {
        #expect(LocalNetworkAccess.errno(in: POSIXError(.EHOSTUNREACH)) == EHOSTUNREACH)
        #expect(LocalNetworkAccess.errno(in: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == EPERM)
        #expect(LocalNetworkAccess.errno(in: NIOStyleIOError(errnoCode: ENETUNREACH)) == ENETUNREACH)
        #expect(LocalNetworkAccess.errno(in: Wrapped(underlying: NIOStyleIOError(errnoCode: EACCES))) == EACCES)
        #expect(LocalNetworkAccess.errno(in: WingTransportError.notStarted) == nil)
    }

    @Test func iOSBroadcastDiscoveryIsUnsupportedWithoutTheMulticastEntitlement() {
        func status(iOS: Bool, entitled: Bool) -> PermissionStatus {
            LocalNetworkAccess.broadcastDiscovery(isIOS: iOS, hasMulticastEntitlement: entitled).status
        }
        #expect(status(iOS: true, entitled: false) == .unsupported)
        #expect(status(iOS: true, entitled: true) == .unknown)
        #expect(status(iOS: false, entitled: false) == .unknown)
        #expect(!LocalNetworkAccess.hasMulticastEntitlement)
        #if os(iOS)
        #expect(LocalNetworkAccess.currentBroadcastDiscovery.status == .unsupported)
        #endif
    }

    @Test func startupReconnectRequiresOptInAndOnDeviceGrantEvidence() {
        func allowed(optedIn: Bool = true, testing: Bool = false, uiTesting: Bool = false,
                     connected: Bool = false, lastHost: Bool = true, grant: Bool = true) -> Bool {
            StartupReconnectPolicy(
                userOptedIn: optedIn, isTesting: testing, isUITesting: uiTesting, isConnected: connected,
                hasLastHost: lastHost, hasLocalNetworkGrant: grant).shouldReconnect
        }
        #expect(allowed())
        #expect(!allowed(optedIn: false), "Launch reconnect is opt-in")
        #expect(!allowed(grant: false), "A synced/restored host without a grant would prompt at launch")
        #expect(!allowed(testing: true))
        #expect(!allowed(uiTesting: true))
        #expect(!allowed(connected: true))
        #expect(!allowed(lastHost: false))
    }

    @Test func startupGateIsOffByDefaultAndStillNeedsEvidenceWhenOptedIn() throws {
        let evidence = Self.temporaryEvidence()
        defer { try? FileManager.default.removeItem(at: evidence.directory) }
        let model = AppModel(hardware: Self.factories(evidence: evidence))
        let savedHost = model.lastHost
        let savedOptIn = AppPersistence.defaults.object(forKey: AppModel.reconnectAtLaunchKey)
        defer {
            model.lastHost = savedHost
            AppPersistence.defaults.set(savedOptIn, forKey: AppModel.reconnectAtLaunchKey)
        }
        AppPersistence.defaults.removeObject(forKey: AppModel.reconnectAtLaunchKey)
        model.lastHost = Self.host
        evidence.recordGrant(for: Self.host)
        func allowed() -> Bool { model.allowsStartupReconnect(isTesting: false, isUITesting: false) }

        #expect(!model.reconnectsAtLaunch, "Default is off")
        #expect(!allowed(), "Default launch performs no network activity, even with evidence and a last host")

        model.reconnectsAtLaunch = true
        #expect(AppPersistence.defaults.bool(forKey: "fluxklang.reconnectAtLaunch"))
        #expect(allowed())
        evidence.clear()
        #expect(!allowed(), "Opted in without on-device evidence: launch must not touch the network")
        evidence.recordGrant(for: "192.0.2.99")
        #expect(!allowed(), "Evidence for another host must not count")
        evidence.recordGrant(for: Self.host)
        #expect(allowed())
        #expect(!model.allowsStartupReconnect(isTesting: true, isUITesting: false))
        #expect(!model.allowsStartupReconnect(isTesting: false, isUITesting: true))
        #expect(!model.allowsStartupReconnect())
    }

    @Test func grantEvidenceIsHostAndBundleScopedAndExcludedFromBackup() throws {
        let evidence = Self.temporaryEvidence()
        defer { try? FileManager.default.removeItem(at: evidence.directory) }
        #expect(!evidence.hasGrant)

        evidence.recordGrant(for: Self.host)

        #expect(evidence.hasGrant(for: Self.host))
        #expect(!evidence.hasGrant(for: "192.0.2.11"))
        let otherApp = LocalNetworkGrantEvidence(directory: evidence.directory, bundleID: "org.example.other")
        #expect(!otherApp.hasGrant(for: Self.host))
        let excluded = try evidence.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(excluded.isExcludedFromBackup == true)
        let identity = try evidence.fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        evidence.recordGrant(for: Self.host)
        let unchanged = try evidence.fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        #expect(identity.fileResourceIdentifier?.isEqual(unchanged.fileResourceIdentifier) == true)

        evidence.clear(host: "192.0.2.11")
        #expect(evidence.hasGrant(for: Self.host), "Clearing another host keeps this record")
        evidence.clear(host: Self.host)
        #expect(!evidence.hasGrant)
    }

    @Test func isolatedTransportConstructionIsPassive() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        let transport = WingTransport(mirroring: audit)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.passiveConstruction, for: .wingTransport) == 1)
        #expect(snapshot.count(.factoryEvaluated, for: .wingTransport) == 0)
        #expect(snapshot.count(.attempted, for: .wingTransport) == 0)
        #expect(snapshot.count(.denied, for: .wingTransport) == 0)
        #expect(snapshot.count(.apiEntered, for: .wingTransport) == 0)
        _ = transport
    }

    @Test(arguments: [(false, false), (true, false), (true, true)])
    func isolatedTransportDeniesSocketCreation(broadcast: Bool, emptyPeers: Bool) async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        let calls = Mutex<[String]>([])
        let peers: Set<String> = emptyPeers ? [] : [Self.host, "192.0.2.11"]
        let remoteHost = broadcast ? "255.255.255.255" : Self.host
        let transport = WingTransport(localNetworkProbe: { host, port in
            calls.withLock { $0.append("probe \(host):\(port)") }
            return nil
        }, resolvePeers: { host in
            calls.withLock { $0.append("resolve \(host)") }
            return peers
        }, mirroring: audit)

        await #expect(throws: WingTransportError.notAuthorized) {
            try await transport.start(remoteHost: remoteHost, broadcast: broadcast)
        }
        let expected = ["resolve \(remoteHost)"] + (broadcast ? [] : peers.sorted().map {
            "probe \($0):\(WingNetwork.defaultPort)"
        })
        #expect(calls.withLock { $0 } == expected)
        #expect(await transport.sessionID == nil)
        #expect(await transport.peerHosts.isEmpty)
        await #expect(throws: WingTransportError.notStarted) {
            try await transport.send("/ch/1/fdr")
        }
        await transport.stop()
        await transport.stop()
        #expect(await transport.sessionID == nil)
        #expect(await transport.peerHosts.isEmpty)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .wingTransport) == 1)
        #expect(snapshot.count(.denied, for: .wingTransport) == 1)
        #expect(snapshot.count(.apiEntered, for: .wingTransport) == 0)
    }

    @Test func manualIPConnectReportsLocalNetworkDenialInsteadOfConnecting() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        let calls = Mutex<[String]>([])
        let transport = WingTransport(localNetworkProbe: { host, port in
            calls.withLock { $0.append("probe \(host):\(port)") }
            return EHOSTUNREACH
        }, resolvePeers: { host in
            calls.withLock { $0.append("resolve \(host)") }
            // Deliberately unordered peers; lexical sorting puts .10 before .11 and .2.
            return ["192.0.2.2", host, "192.0.2.11"]
        }, mirroring: audit)
        let controller = WingController(transport: transport)

        await controller.connect(host: Self.host)

        guard case .failed(let reason) = controller.connection else {
            Issue.record("Expected a truthful failure, got \(controller.connection)")
            return
        }
        #expect(reason == LocalNetworkAccess.connectFailureReason(errno: EHOSTUNREACH, host: Self.host))
        #expect(controller.transportWriteCount == 0)
        #expect(await transport.sessionID == nil, "No socket may open after a blocked probe")
        #expect(await transport.peerHosts.isEmpty)
        #expect(calls.withLock { $0 } == ["resolve \(Self.host)", "probe \(Self.host):\(WingNetwork.defaultPort)"],
                "Resolve first, probe the first sorted peer, then stop immediately on denial")
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .wingTransport) == 0)
        #expect(snapshot.count(.denied, for: .wingTransport) == 0)
        #expect(snapshot.count(.apiEntered, for: .wingTransport) == 0)
    }

    @Test func blockedProbeThrowsBeforeAnySocketOpens() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        let transport = WingTransport(localNetworkProbe: { _, _ in ECONNREFUSED }, resolvePeers: { [$0] },
                                      mirroring: audit)
        await #expect(throws: WingTransportError.localNetworkBlocked(errno: ECONNREFUSED, host: Self.host)) {
            try await transport.start(remoteHost: Self.host, localPort: nil, broadcast: false)
        }
        let message = WingTransportError.localNetworkBlocked(errno: ECONNREFUSED, host: Self.host)
            .localizedDescription
        #expect(message.hasPrefix("Couldn't open a network path to 192.0.2.10"))
        #expect(await transport.sessionID == nil)
        await #expect(throws: WingTransportError.notStarted) {
            try await transport.send("/ch/1/fdr")
        }
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .wingTransport) == 0)
        #expect(snapshot.count(.denied, for: .wingTransport) == 0)
        #expect(snapshot.count(.apiEntered, for: .wingTransport) == 0)
    }

    @Test func unresolvedPeerStillFailsBeforeThePermissionProbe() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        let transport = WingTransport(localNetworkProbe: { _, _ in
            Issue.record("An unresolved peer must not reach the permission probe")
            return EHOSTUNREACH
        }, resolvePeers: { _ in [] }, mirroring: audit)
        await #expect(throws: WingTransportError.unresolvedPeer) {
            try await transport.start(remoteHost: "unresolved.invalid")
        }
        #expect(await transport.sessionID == nil)
        #expect(await transport.peerHosts.isEmpty)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .wingTransport) == 0)
        #expect(snapshot.count(.denied, for: .wingTransport) == 0)
        #expect(snapshot.count(.apiEntered, for: .wingTransport) == 0)
    }

    @Test func unentitledDiscoveryExplainsItselfWithoutScanning() async {
        let unsupported = LocalNetworkAccess.broadcastDiscovery(isIOS: true, hasMulticastEntitlement: false)
        let discovery = WingDiscovery(broadcastPermission: unsupported)

        await discovery.scan(duration: .zero)

        #expect(discovery.unavailableReason == unsupported.reason)
        #expect(discovery.responders.isEmpty)
        #expect(!discovery.isScanning)
    }

    @Test func testHostsGetAnInertPermissionProbe() async {
        let probe = HardwareServiceFactories.current.makePermissionProbe()
        #expect(probe is InertPermissionProbe)
        #expect(HardwareServiceFactories.inert.makePermissionProbe() is InertPermissionProbe)
        var makes = 0
        let injected = InertPermissionProbe()
        var factories = HardwareServiceFactories.inert
        factories.makePermissionProbe = { makes += 1; return injected }
        let isolated = HardwareServiceFactories.select(isTesting: true, production: factories)
        #expect(isolated.makePermissionProbe() !== injected)
        #expect(makes == 0)
        let selected = HardwareServiceFactories.select(isTesting: false, production: factories)
        #expect(makes == 0, "Selection must not construct a permission probe")
        #expect(selected.makePermissionProbe() === injected)
        #expect(makes == 1)
        #expect(probe.state(of: .microphone).status == .unknown)
        let inert = InertPermissionProbe()
        _ = await inert.request(.microphone)
        #expect(inert.requests == [.microphone])
    }

    @Test func failedProbesOnTheAppConnectPathRecordNoEvidence() async {
        let evidence = Self.temporaryEvidence()
        defer { try? FileManager.default.removeItem(at: evidence.directory) }
        for (code, keepsStaleRecord) in [(EHOSTUNREACH, false), (ENETUNREACH, true)] {
            evidence.recordGrant(for: Self.host)
            let model = AppModel(hardware: Self.factories(evidence: evidence, probe: { _, _ in code }))
            let savedHost = model.lastHost

            await model.connect(host: Self.host)

            #expect(!model.isConnected)
            #expect(evidence.hasGrant(for: Self.host) == keepsStaleRecord,
                    "Only a possible denial (\(code)) clears the startup evidence")
            #expect(model.lastHost == savedHost)
            evidence.clear()
            await model.connect(host: Self.host)
            #expect(!evidence.hasGrant, "A failed connect never records evidence")
        }
    }

    @Test func successfulAppConnectRecordsEvidenceForThatHost() async {
        let evidence = Self.temporaryEvidence()
        defer { try? FileManager.default.removeItem(at: evidence.directory) }
        var factories = Self.factories(evidence: evidence)
        factories.makeWingTransport = { _, _ in AssistantRecordingWingTransport() }
        let model = AppModel(assistant: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
                             hardware: factories)
        let savedHost = model.lastHost
        defer { model.lastHost = savedHost }

        await model.connect(host: Self.host)

        #expect(model.isConnected)
        #expect(evidence.hasGrant(for: Self.host))
        #expect(model.lastHost == Self.host)
        await model.wing.disconnect()
    }

    private static func temporaryEvidence() -> LocalNetworkGrantEvidence {
        LocalNetworkGrantEvidence(
            directory: AppPersistence.directory.appendingPathComponent("permission-\(UUID().uuidString)"),
            bundleID: "org.davidjensenius.FluxKlang.tests")
    }

    private static func factories(
        evidence: LocalNetworkGrantEvidence,
        probe: @escaping LocalNetworkProbe.Check = { _, _ in ENETUNREACH }
    ) -> HardwareServiceFactories {
        var factories = HardwareServiceFactories.inert
        factories.localNetworkEvidence = evidence
        factories.localNetworkProbe = probe
        // Exercise the real denial/evidence logic, but replace peer resolution with a pure double.
        // Callers here supply a failing probe; successful connects use a recording transport instead.
        factories.makeWingTransport = {
            WingTransport(remotePort: $0, localNetworkProbe: $1, resolvePeers: { [$0] })
        }
        return factories
    }
}
